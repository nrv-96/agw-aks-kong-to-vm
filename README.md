# hello-app

Simple Java 21 Hello World HTTP application that listens on port **8100** and prints the host name of the machine it runs on.

## Requirements

- JDK 21 (installed at `C:\Program Files\Java\jdk-21.0.12`)
- Maven 3.9+

## Build

```bash
mvn clean package
```

The POM contains a `fork-jdk21-compiler` profile that is activated automatically when
`C:\Program Files\Java\jdk-21.0.12\bin\javac.exe` exists. It forks that JDK 21 `javac`,
so the build succeeds even when Maven itself runs on JDK 17 (which is what `mvn -version`
reports on this machine). If your JDK 21 lives elsewhere, either set `JAVA_HOME` to it:

```powershell
$env:JAVA_HOME='C:\Program Files\Java\jdk-21.0.12'
mvn clean package
```

or update the `<executable>` path in the profile inside `pom.xml`.

## Run

Run the jar with Java 21 (this app uses virtual threads, so it will not start on 17):

```bash
"C:\Program Files\Java\jdk-21.0.12\bin\java.exe" -jar target/hello-app.jar
```

## Test

```bash
curl http://localhost:8100
```

Expected output:

```
Hello World!
Host name: <your-machine-name>
```

Health check:

```bash
curl http://localhost:8100/health
```

Returns HTTP `200` with JSON:

```json
{
  "status": "UP",
  "service": "hello-app",
  "host": "<your-machine-name>",
  "message": "Hello World works",
  "uptimeSeconds": 1
}
```
