package com.example.hello;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executors;

/**
 * Minimal Java 21 "Hello World" HTTP application.
 *
 * <p>Listens on port 8100. {@code /} answers with the host name of the machine
 * the application is running on, and {@code /health} reports whether the
 * application is up.</p>
 */
public final class HelloApplication {

    /** Port the HTTP server listens on. */
    private static final int PORT = 8100;

    private HelloApplication() {
    }

    public static void main(String[] args) throws IOException {
        String hostName = resolveHostName();
        long startedAtNanos = System.nanoTime();

        HttpServer server = HttpServer.create(new InetSocketAddress(PORT), 0);

        // Longest matching context path wins, so /health takes precedence over /.
        server.createContext("/health", exchange -> {
            long uptimeSeconds = (System.nanoTime() - startedAtNanos) / 1_000_000_000L;
            String body = """
                    {
                      "status": "UP",
                      "service": "hello-app",
                      "host": "%s",
                      "message": "Hello World works",
                      "uptimeSeconds": %d
                    }""".formatted(hostName, uptimeSeconds);
            send(exchange, 200, "application/json; charset=utf-8", body);
        });

        server.createContext("/", exchange -> {
            String body = """
                    Hello World!
                    Host name: %s
                    """.formatted(hostName);
            send(exchange, 200, "text/plain; charset=utf-8", body);
        });

        server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
        server.start();

        System.out.printf("Hello World! Listening on http://0.0.0.0:%d (host name: %s)%n", PORT, hostName);
    }

    /** Writes a UTF-8 response and closes the exchange. */
    private static void send(HttpExchange exchange, int status, String contentType, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", contentType);
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(bytes);
        }
    }

    /** Resolves the machine host name, falling back to environment variables. */
    private static String resolveHostName() {
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
}
