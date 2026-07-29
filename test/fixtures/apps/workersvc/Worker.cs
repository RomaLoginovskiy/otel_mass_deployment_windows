// Explicit: the Worker SDK's implicit usings cover Microsoft.Extensions.* but not System.Net.Http,
// where IHttpClientFactory lives.
using System.Net.Http;

namespace CxWorkerSvc;

/// <summary>
/// Calls a URL on a timer. The point is the outbound call, not the result: it is what the CLR
/// profiler turns into a client span, and spans are what the matrix gates on.
/// </summary>
public class Worker : BackgroundService
{
    private readonly IHttpClientFactory _factory;
    private readonly ILogger<Worker> _log;
    private readonly string _target;
    private readonly int _intervalSeconds;

    public Worker(IHttpClientFactory factory, ILogger<Worker> log, IConfiguration config)
    {
        _factory = factory;
        _log = log;
        // Environment first so the matrix can point the service at whichever fixture it provisioned
        // without rebuilding it.
        _target = Environment.GetEnvironmentVariable("CX_WORKER_TARGET")
                  ?? config["WorkerTarget"]
                  ?? "http://127.0.0.1/coreweb-net8/ping";
        _intervalSeconds = int.TryParse(Environment.GetEnvironmentVariable("CX_WORKER_INTERVAL"), out var s) && s > 0
            ? s : 10;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _log.LogInformation("cxworkersvc starting; target={Target} interval={Interval}s", _target, _intervalSeconds);

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                var client = _factory.CreateClient();
                client.Timeout = TimeSpan.FromSeconds(10);
                var body = await client.GetStringAsync(_target, stoppingToken);
                _log.LogInformation("cxworkersvc tick ok; bytes={Bytes}", body.Length);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;   // shutting down, not a failure
            }
            catch (Exception ex)
            {
                // Keep ticking. A dead target must not stop the service, or a fixture ordering
                // problem would look like an instrumentation failure.
                _log.LogWarning(ex, "cxworkersvc tick failed");
            }

            try { await Task.Delay(TimeSpan.FromSeconds(_intervalSeconds), stoppingToken); }
            catch (OperationCanceledException) { break; }
        }

        _log.LogInformation("cxworkersvc stopping");
    }
}
