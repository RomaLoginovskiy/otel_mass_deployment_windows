// Minimal ASP.NET Core target for the full-matrix E2E.
//
// Deliberately small, but not trivial: /work makes an OUTBOUND HttpClient call to its own /ping,
// so each request produces a server span AND a client span with a parent-child link. A fixture
// that only served a static string would let a broken trace pipeline still look like a pass,
// because a single orphan span proves much less than a connected pair.
//
// Nothing here references OpenTelemetry. The whole point of the matrix is that instrumentation is
// zero-code: the CLR profiler the deploy scripts register is what produces the telemetry, so an
// app that imported the SDK would be testing the wrong thing.

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddHttpClient();
var app = builder.Build();

// Which runtime actually loaded this - asserted by the matrix so a mislabelled pool cannot pass.
var runtime = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription;

app.MapGet("/", () => Results.Text($"coreweb up on {runtime}\n"));

app.MapGet("/ping", () => Results.Text("pong\n"));

app.MapGet("/work", async (IHttpClientFactory factory, HttpContext ctx) =>
{
    var client = factory.CreateClient();
    var self = $"{ctx.Request.Scheme}://{ctx.Request.Host}";
    string inner;
    try
    {
        inner = await client.GetStringAsync($"{self}/ping");
    }
    catch (Exception ex)
    {
        // Reported, not thrown: an outbound failure should still leave a span to look at, and the
        // matrix asserts on spans rather than on this body.
        inner = $"inner call failed: {ex.GetType().Name}";
    }
    return Results.Text($"work done on {runtime}; inner={inner.Trim()}\n");
});

// A route that always throws, so the error path has spans too.
app.MapGet("/boom", () => { throw new InvalidOperationException("boom (deliberate)"); });

app.Run();
