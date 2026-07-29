// A .NET worker running as a Windows service, for the non-IIS instrumentation path.
//
// It has to GENERATE telemetry without any SDK reference of its own (zero-code is the whole
// point), so the work it does is an outbound HTTP call on a timer: the CLR profiler turns that
// into a client span, which is what the matrix gates on. A worker that only wrote log lines would
// pass a "service is running" check while proving nothing about the profiler.
//
// The target URL is configurable because the matrix points it at one of the IIS fixtures on the
// same host - that also lets the matrix check trace CONTINUITY from a service into an IIS app.

using CxWorkerSvc;

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddHttpClient();
builder.Services.AddHostedService<Worker>();

// UseWindowsService is a no-op when started from a console, so the same binary serves both.
builder.Services.AddWindowsService(options =>
{
    options.ServiceName = "cxworkersvc";
});

var host = builder.Build();
host.Run();
