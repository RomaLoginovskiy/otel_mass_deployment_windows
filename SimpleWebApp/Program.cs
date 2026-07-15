using Microsoft.Data.SqlClient;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container.
builder.Services.AddRazorPages();

var app = builder.Build();

// Configure the HTTP request pipeline.
if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error");
    // The default HSTS value is 30 days. You may want to change this for production scenarios, see https://aka.ms/aspnetcore-hsts.
    app.UseHsts();
}

app.UseHttpsRedirection();

app.UseStaticFiles();

app.UseRouting();

app.UseAuthorization();

app.MapRazorPages();

// Lightweight liveness endpoint to confirm the process is running under IIS.
app.MapGet("/health", () => Results.Json(new
{
    status = "ok",
    machine = Environment.MachineName,
    framework = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription,
    utc = DateTime.UtcNow
}));

// DB endpoint: issues a real SQL Server query so the OTel .NET auto-instrumentation
// emits a SqlClient client span (db.system=mssql, db.name from Initial Catalog),
// which feeds the DB span-metrics pipeline in the collector. A failed query still
// produces a span with error status, so it also exercises the error metrics.
app.MapGet("/db", async (IConfiguration config) =>
{
    var cs = config.GetConnectionString("Sql");
    if (string.IsNullOrWhiteSpace(cs))
    {
        return Results.Problem("No 'Sql' connection string configured (ConnectionStrings:Sql).", statusCode: 500);
    }

    try
    {
        await using var conn = new SqlConnection(cs);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand("SELECT COUNT(*) FROM sys.objects", conn);
        var objectCount = Convert.ToInt32(await cmd.ExecuteScalarAsync() ?? 0);
        return Results.Json(new
        {
            status = "ok",
            database = conn.Database,
            objectCount,
            utc = DateTime.UtcNow
        });
    }
    catch (Exception ex)
    {
        return Results.Problem("DB query failed: " + ex.Message, statusCode: 500);
    }
});

app.Run();
