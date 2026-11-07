package com.example.hello;

import com.sun.net.httpserver.HttpsServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.TrustManagerFactory;
import javax.net.ssl.X509TrustManager;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.SecureRandom;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Local HTTPS smoke tests. The keystore and certificate are generated with the
 * JDK's keytool so the tests do not depend on OpenSSL or a pre-installed
 * certificate.
 */
class HelloApplicationTest {

    private static final String KEYSTORE_PASSWORD = "changeit";
    private static final String KEYSTORE_ALIAS = "hello-app";

    @TempDir
    Path tempDirectory;

    private Path keystore;
    private Path certificate;

    @BeforeEach
    void createKeystore() throws Exception {
        keystore = tempDirectory.resolve("keystore.p12");
        certificate = tempDirectory.resolve("hello-app.pem");

        runKeytool(
                "-genkeypair",
                "-alias", KEYSTORE_ALIAS,
                "-keyalg", "RSA",
                "-keysize", "2048",
                "-validity", "1",
                "-dname", "CN=localhost",
                "-ext", "SAN=dns:localhost,ip:127.0.0.1",
                "-storetype", "PKCS12",
                "-keystore", keystore.toString(),
                "-storepass", KEYSTORE_PASSWORD,
                "-keypass", KEYSTORE_PASSWORD);
        runKeytool(
                "-exportcert",
                "-rfc",
                "-alias", KEYSTORE_ALIAS,
                "-keystore", keystore.toString(),
                "-storepass", KEYSTORE_PASSWORD,
                "-file", certificate.toString());

        System.setProperty("TLS_KEYSTORE_PATH", keystore.toString());
        System.setProperty("TLS_KEYSTORE_PASSWORD", KEYSTORE_PASSWORD);
        System.setProperty("TLS_KEYSTORE_TYPE", "PKCS12");
    }

    @AfterEach
    void clearTlsProperties() {
        System.clearProperty("TLS_KEYSTORE_PATH");
        System.clearProperty("TLS_KEYSTORE_PASSWORD");
        System.clearProperty("TLS_KEYSTORE_TYPE");
    }

    @Test
    void servesTheSameHealthJsonOverHttpsOnRootAndHealth() throws Exception {
        SSLContext serverContext = HelloApplication.TlsConfiguration.load();
        HttpsServer server = HelloApplication.createServer(0, serverContext);
        server.start();
        int port = server.getAddress().getPort();
        try {
            HttpClient client = HttpClient.newBuilder()
                    .sslContext(trustAllContext())
                    .build();

            HttpResponse<String> root = get(client, "https://localhost:" + port + "/");
            assertEquals(200, root.statusCode());
            assertHealthJson(root.body());

            HttpResponse<String> health = get(client, "https://localhost:" + port + "/health");
            assertEquals(200, health.statusCode());
            assertHealthJson(health.body());
            assertTrue(health.headers().firstValue("content-type").orElse("")
                    .startsWith("application/json"));
        } finally {
            server.stop(0);
        }
    }

    @Test
    void servesHttpsWhenTheGeneratedCertificateIsTrusted() throws Exception {
        SSLContext serverContext = HelloApplication.TlsConfiguration.load();
        HttpsServer server = HelloApplication.createServer(0, serverContext);
        server.start();
        int port = server.getAddress().getPort();
        try {
            // Normal path: the generated certificate is the only trust anchor, so
            // chain and hostname (SAN=dns:localhost) validation are exercised.
            HttpClient client = HttpClient.newBuilder()
                    .sslContext(trustingContext(certificate))
                    .build();

            HttpResponse<String> response =
                    get(client, "https://localhost:" + port + "/health");
            assertEquals(200, response.statusCode());
            assertHealthJson(response.body());
        } finally {
            server.stop(0);
        }
    }

    @Test
    void rejectsPlainHttpOnTheTlsPort() throws Exception {
        SSLContext serverContext = HelloApplication.TlsConfiguration.load();
        HttpsServer server = HelloApplication.createServer(0, serverContext);
        server.start();
        int port = server.getAddress().getPort();
        try {
            HttpClient client = HttpClient.newHttpClient();
            assertThrows(IOException.class, () -> client.send(
                    HttpRequest.newBuilder(URI.create("http://localhost:" + port + "/")).GET().build(),
                    HttpResponse.BodyHandlers.ofString()));
        } finally {
            server.stop(0);
        }
    }

    @Test
    void failsFastWhenThePasswordIsMissing() {
        System.setProperty("TLS_KEYSTORE_PASSWORD", "");
        assertThrows(IllegalStateException.class, HelloApplication.TlsConfiguration::load);
    }

    @Test
    void failsFastWhenTheKeystoreIsMissing() {
        System.setProperty("TLS_KEYSTORE_PATH", tempDirectory.resolve("missing.p12").toString());
        assertThrows(IllegalStateException.class, HelloApplication.TlsConfiguration::load);
    }

    @Test
    void failsFastWhenTheKeystorePasswordIsWrong() {
        System.setProperty("TLS_KEYSTORE_PASSWORD", "definitely-not-the-password");
        assertThrows(IOException.class, HelloApplication.TlsConfiguration::load);
    }

    @Test
    void failsFastWhenTheKeystoreHasNoPrivateKey() throws Exception {
        Path trustOnly = tempDirectory.resolve("trust-only.p12");
        runKeytool(
                "-importcert",
                "-noprompt",
                "-alias", "trusted-cert",
                "-file", certificate.toString(),
                "-keystore", trustOnly.toString(),
                "-storetype", "PKCS12",
                "-storepass", KEYSTORE_PASSWORD);

        System.setProperty("TLS_KEYSTORE_PATH", trustOnly.toString());
        assertThrows(IllegalStateException.class, HelloApplication.TlsConfiguration::load);
    }

    private static HttpResponse<String> get(HttpClient client, String url) throws Exception {
        return client.send(
                HttpRequest.newBuilder(URI.create(url)).GET().build(),
                HttpResponse.BodyHandlers.ofString());
    }

    private static void assertHealthJson(String body) {
        assertTrue(body.startsWith("{\"status\":\"UP\""), "unexpected JSON: " + body);
        assertTrue(body.contains("\"service\":\"hello-app\""), "unexpected JSON: " + body);
        assertTrue(body.contains("\"host\":\""), "unexpected JSON: " + body);
    }

    private static void runKeytool(String... arguments) throws Exception {
        Path keytool = Path.of(
                System.getProperty("java.home"), "bin",
                System.getProperty("os.name").toLowerCase().contains("win")
                        ? "keytool.exe" : "keytool");
        List<String> command = new ArrayList<>();
        command.add(keytool.toString());
        command.addAll(Arrays.asList(arguments));

        Process process = new ProcessBuilder(command)
                .redirectErrorStream(true)
                .start();
        if (!process.waitFor(60, TimeUnit.SECONDS)) {
            process.destroyForcibly();
            throw new AssertionError("keytool timed out");
        }
        String output = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
        assertEquals(0, process.exitValue(), "keytool failed:\n" + output);
    }

    /** Builds a trust store containing only the generated server certificate. */
    private static SSLContext trustingContext(Path certificateFile) throws Exception {
        KeyStore trustStore = KeyStore.getInstance(KeyStore.getDefaultType());
        trustStore.load(null, null);
        try (InputStream input = Files.newInputStream(certificateFile)) {
            Certificate generated = CertificateFactory.getInstance("X.509")
                    .generateCertificate(input);
            trustStore.setCertificateEntry("hello-app", generated);
        }
        TrustManagerFactory trustManagers =
                TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        trustManagers.init(trustStore);
        SSLContext context = SSLContext.getInstance("TLS");
        context.init(null, trustManagers.getTrustManagers(), new SecureRandom());
        return context;
    }

    /**
     * Test-only trust manager used by the basic smoke test: the certificate is
     * self-signed. {@link #servesHttpsWhenTheGeneratedCertificateIsTrusted}
     * covers the normal validation path with a real trust anchor.
     */
    private static SSLContext trustAllContext() throws Exception {
        TrustManager[] trustAll = {new X509TrustManager() {
            @Override
            public void checkClientTrusted(X509Certificate[] chain, String authType) {
                // test-only
            }

            @Override
            public void checkServerTrusted(X509Certificate[] chain, String authType) {
                // test-only
            }

            @Override
            public X509Certificate[] getAcceptedIssuers() {
                return new X509Certificate[0];
            }
        }};
        SSLContext context = SSLContext.getInstance("TLS");
        context.init(null, trustAll, new SecureRandom());
        return context;
    }
}
