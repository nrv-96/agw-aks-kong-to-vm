package com.example.hello;

import com.sun.net.httpserver.HttpsServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Local HTTPS smoke tests. The keystore is generated with the JDK's keytool so
 * the tests do not depend on OpenSSL or a pre-installed certificate.
 */
class HelloApplicationTest {

    private static final String KEYSTORE_PASSWORD = "changeit";
    private static final String KEYSTORE_ALIAS = "hello-app";

    @TempDir
    Path tempDirectory;

    private Path keystore;

    @BeforeEach
    void createKeystore() throws Exception {
        keystore = tempDirectory.resolve("keystore.p12");
        Path keytool = Path.of(
                System.getProperty("java.home"), "bin",
                System.getProperty("os.name").toLowerCase().contains("win")
                        ? "keytool.exe" : "keytool");
        Process process = new ProcessBuilder(
                keytool.toString(),
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
                "-keypass", KEYSTORE_PASSWORD)
                .redirectErrorStream(true)
                .start();
        if (!process.waitFor(60, TimeUnit.SECONDS)) {
            process.destroyForcibly();
            throw new AssertionError("keytool timed out");
        }
        String output = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
        assertEquals(0, process.exitValue(), "keytool failed:\n" + output);

        System.setProperty("TLS_KEYSTORE_PATH", keystore.toString());
        System.setProperty("TLS_KEYSTORE_PASSWORD", KEYSTORE_PASSWORD);
        System.setProperty("TLS_KEYSTORE_TYPE", "PKCS12");
    }

    @AfterEach
    void clearTlsProperties() {
        System.clearProperty("TLS_KEYSTORE_PATH");
        System.clearProperty("TLS_KEYSTORE_PASSWORD");
        System.clearProperty("TLS_KEYSTORE_TYPE");
        System.clearProperty("TLS_KEY_ALIAS");
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

    /**
     * Test-only trust manager: the generated certificate is self-signed. The
     * hostname is still validated by the HTTP client against SAN=localhost.
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
