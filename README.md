# hello-app

Simple Java 21 "Hello World" **HTTPS** application that listens on port **8100**
and returns the host name of the machine it runs on. It is the backend used to
demonstrate Kong TLS verification and load balancing between two Linux VMs.

## Requirements

- JDK 21 (installed at `C:\Program Files\Java\jdk-21.0.12`)
- Maven 3.9+
- `keytool` (ships with the JDK) for local keystore generation

## Build and test

```bash
mvn clean package
```

The POM contains a `fork-jdk21-compiler` profile that is activated automatically when
`C:\Program Files\Java\jdk-21.0.12\bin\javac.exe` exists. It forks that JDK 21 `javac`
and runs the tests on JDK 21, so `mvn clean package` works even when Maven itself runs
on JDK 17 (which is what `mvn -version` reports on this machine). If your JDK 21 lives
elsewhere, either set `JAVA_HOME` to it:

```powershell
$env:JAVA_HOME='C:\Program Files\Java\jdk-21.0.12'
mvn clean package
```

or update the paths in the profile inside `pom.xml`.

`mvn test` runs local HTTPS smoke tests covering:

- `/` and `/health` return the same JSON over HTTPS,
- the normal certificate-validation path using the generated certificate as the trust anchor,
- plain HTTP against the TLS port is rejected,
- startup fails fast when the keystore/password is missing, the password is wrong, or the keystore contains no private-key entry.

## TLS configuration

The application **only** serves HTTPS. There is no plaintext fallback. It reads:

| Variable | Default | Meaning |
| --- | --- | --- |
| `TLS_KEYSTORE_PATH` | `/etc/hello/tls/keystore.p12` | PKCS#12 keystore with certificate + private key |
| `TLS_KEYSTORE_PASSWORD` | *(required)* | Keystore/key password |
| `TLS_KEYSTORE_TYPE` | `PKCS12` | Keystore type |
| `PORT` | `8100` | HTTPS listening port |

If the keystore, key, or password is missing or invalid, the process exits non-zero
with a clear error. TLS 1.2 and TLS 1.3 are enabled.

The keystore must contain **one private-key entry**. Alias selection is not supported;
keep one key per keystore (as the VM automation does).

## Run locally

```powershell
# 1. Generate a throwaway self-signed keystore (local test only)
keytool -genkeypair -alias hello-app -keyalg RSA -keysize 2048 -validity 1 `
  -dname "CN=localhost" -ext "SAN=dns:localhost,ip:127.0.0.1" `
  -storetype PKCS12 -keystore .\target\keystore.p12 `
  -storepass changeit -keypass changeit

# 2. Point the app at it (JDK 21 is required for virtual threads)
$env:TLS_KEYSTORE_PATH = "$PWD\target\keystore.p12"
$env:TLS_KEYSTORE_PASSWORD = "changeit"
& "C:\Program Files\Java\jdk-21.0.12\bin\java.exe" -jar target\hello-app.jar
```

Expected startup line:

```
Hello World! Listening on https://0.0.0.0:8100 (host name: <your-machine-name>)
```

## Test

```bash
# Self-signed local certificate: -k is acceptable only for this local smoke test
curl -k https://localhost:8100/
curl -k https://localhost:8100/health
```

Both return HTTP `200` with:

```json
{"status":"UP","service":"hello-app","host":"<your-machine-name>"}
```

To verify the certificate instead of using `-k`:

```powershell
keytool -exportcert -rfc -alias hello-app `
  -keystore .\target\keystore.p12 -storepass changeit > .\target\localhost.crt
curl.exe --cacert .\target\localhost.crt https://localhost:8100/health
```

Plain HTTP must fail:

```bash
curl -v http://localhost:8100/   # connection reset / TLS error
```

## VM deployment contract (later phase)

On each VM the automation will:

1. generate the private key **on the VM** and submit only a CSR,
2. install the signed certificate (SAN `DNS:pairs-monitor.be.com`) + chain,
3. create `/etc/hello/tls/keystore.p12` with `openssl pkcs12`,
4. start the app with `TLS_KEYSTORE_PATH` and `TLS_KEYSTORE_PASSWORD` supplied via a
   `0600` systemd `EnvironmentFile`.

The VM private key never leaves the VM and is never stored in Key Vault.
