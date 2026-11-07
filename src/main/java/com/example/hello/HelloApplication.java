package com.example.hello;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpsConfigurator;
import com.sun.net.httpserver.HttpsParameters;
import com.sun.net.httpserver.HttpsServer;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.util.concurrent.Executors;

/**
 * Minimal Java 21 "Hello World" HTTPS application.
 *
 * <p>Listens on port 8100 (override with {@code PORT}) using TLS only. Both
 * {@code /} and {@code /health} return:</p>
 *
 * <pre>{"status":"UP","service":"hello-app","host":"&lt;hostname&gt;"}</pre>
 *
 * <p>TLS material is loaded from a PKCS#12 keystore. The application fails fast
 * when the keystore or password is missing: there is no plaintext fallback.</p>
 */
public final class HelloApplication {

    /** Default HTTPS port. */
    private static final int DEFAULT_PORT = 8100;

    /** Supported TLS protocol versions, newest first. */
    private static final String[] TLS_PROTOCOLS = {"TLSv1.3", "TLSv1.2"};

    private HelloApplication() {
    }

    public static void main(String[] args) {
        try {
            int port = resolvePort();
            SSLContext sslContext = TlsConfiguration.load();
            HttpsServer server = createServer(port, sslContext);
            server.start();
            System.out.printf(
                    "Hello World! Listening on https://0.0.0.0:%d (host name: %s)%n",
                    server.getAddress().getPort(), resolveHostName());
        } catch (Exception error) {
            System.err.println("FATAL: unable to start the HTTPS server: " + error.getMessage());
            error.printStackTrace(System.err);
            System.exit(1);
        }
    }

    /**
     * Builds and configures the HTTPS server. Exposed for tests so they can bind
     * an ephemeral port.
     */
    static HttpsServer createServer(int port, SSLContext sslContext) throws IOException {
        String hostName = resolveHostName();
        HttpsServer server = HttpsServer.create(new InetSocketAddress(port), 0);

        server.setHttpsConfigurator(new HttpsConfigurator(sslContext) {
            @Override
            public void configure(HttpsParameters params) {
                SSLParameters sslParameters = getSSLContext().getDefaultSSLParameters();
                sslParameters.setProtocols(TLS_PROTOCOLS);
                sslParameters.setNeedClientAuth(false);
                params.setSSLParameters(sslParameters);
            }
        });

        // Longest matching context path wins, so /health takes precedence over /.
        server.createContext("/health", exchange -> sendJson(exchange, hostName));
        server.createContext("/", exchange -> sendJson(exchange, hostName));
        server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
        return server;
    }

    /** Writes the health/load-balancing JSON response and closes the exchange. */
    private static void sendJson(HttpExchange exchange, String hostName) throws IOException {
        String body = """
                {"status":"UP","service":"hello-app","host":"%s"}""".formatted(escapeJson(hostName));
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        exchange.getResponseHeaders().set("Cache-Control", "no-store");
        exchange.sendResponseHeaders(200, bytes.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(bytes);
        }
    }

    /** Minimal JSON string escaping for the host name. */
    private static String escapeJson(String value) {
        StringBuilder escaped = new StringBuilder(value.length());
        for (int index = 0; index < value.length(); index++) {
            char character = value.charAt(index);
            switch (character) {
                case '"' -> escaped.append("\\\"");
                case '\\' -> escaped.append("\\\\");
                case '\n' -> escaped.append("\\n");
                case '\r' -> escaped.append("\\r");
                case '\t' -> escaped.append("\\t");
                default -> {
                    if (character < 0x20) {
                        escaped.append(String.format("\\u%04x", (int) character));
                    } else {
                        escaped.append(character);
                    }
                }
            }
        }
        return escaped.toString();
    }

    /** Resolves the listening port from {@code PORT} (default 8100). */
    private static int resolvePort() {
        String raw = TlsConfiguration.setting("PORT", Integer.toString(DEFAULT_PORT));
        int port;
        try {
            port = Integer.parseInt(raw);
        } catch (NumberFormatException error) {
            throw new IllegalStateException("PORT must be an integer, got: " + raw, error);
        }
        if (port < 1 || port > 65535) {
            throw new IllegalStateException("PORT must be between 1 and 65535, got: " + port);
        }
        return port;
    }

    /** Resolves the machine host name, falling back to environment variables. */
    static String resolveHostName() {
        try {
            String name = InetAddress.getLocalHost().getHostName();
            if (name != null && !name.isBlank()) {
                return name;
            }
        } catch (IOException ignored) {
            // fall through to environment based lookup
        }
        String env = System.getenv("HOSTNAME");
        if (env == null || env.isBlank()) {
            env = System.getenv("COMPUTERNAME");
        }
        return env == null || env.isBlank() ? "unknown" : env;
    }

    /** Loads the TLS keystore and builds the server {@link SSLContext}. */
    static final class TlsConfiguration {

        private static final String DEFAULT_KEYSTORE = "/etc/hello/tls/keystore.p12";

        private TlsConfiguration() {
        }

        static SSLContext load() throws Exception {
            String keystorePath = setting("TLS_KEYSTORE_PATH", DEFAULT_KEYSTORE);
            String password = setting("TLS_KEYSTORE_PASSWORD", null);
            if (password == null || password.isBlank()) {
                throw new IllegalStateException(
                        "TLS_KEYSTORE_PASSWORD is required; refusing to start without TLS");
            }
            String keystoreType = setting("TLS_KEYSTORE_TYPE", "PKCS12");
            String keyAlias = setting("TLS_KEY_ALIAS", null);

            Path keystore = Path.of(keystorePath);
            if (!Files.isReadable(keystore)) {
                throw new IllegalStateException("TLS keystore is not readable: " + keystore);
            }

            KeyStore store = KeyStore.getInstance(keystoreType);
            try (InputStream input = Files.newInputStream(keystore)) {
                store.load(input, password.toCharArray());
            }
            if (keyAlias != null && !keyAlias.isBlank() && !store.containsAlias(keyAlias)) {
                throw new IllegalStateException(
                        "TLS key alias '" + keyAlias + "' not found in " + keystore);
            }

            KeyManagerFactory keyManagers =
                    KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
            keyManagers.init(store, password.toCharArray());

            SSLContext sslContext = SSLContext.getInstance("TLS");
            sslContext.init(keyManagers.getKeyManagers(), null, null);
            return sslContext;
        }

        /**
         * Reads a system property first, then an environment variable.
         * System properties make the tests independent of the process environment.
         */
        static String setting(String name, String defaultValue) {
            String value = System.getProperty(name);
            if (value == null) {
                value = System.getenv(name);
            }
            return value == null || value.isBlank() ? defaultValue : value;
        }
    }
}
