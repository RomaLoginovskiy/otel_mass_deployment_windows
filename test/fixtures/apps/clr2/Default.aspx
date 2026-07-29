<%@ Page Language="C#" %>
<%--
  CLR **2.0** target for the full-matrix E2E - the REFUSAL path, not a happy path.

  Runs in an app pool with managedRuntimeVersion=v2.0, i.e. the .NET 2.0/3.5 desktop CLR. The
  OpenTelemetry .NET Framework profiler supports 4.x; CLR 2 is out of scope for it. The matrix
  therefore asserts that this app:

    * is classified (not crashed, not guessed at),
    * is NOT claimed in CX_IIS_SERVICES,
    * and produces NO telemetry.

  A silent claim here would be the worst outcome: a service name in Coralogix that never reports,
  which reads as an outage rather than as an unsupported runtime. Kept deliberately 2.0-compatible
  (no LINQ, no var, no generics-heavy syntax) so it really does compile under CLR 2.
--%>
<script runat="server">
    protected void Page_Load(object sender, EventArgs e)
    {
        Response.ContentType = "text/plain";
        Response.Write("clr2 up on CLR " + Environment.Version + "\n");
    }
</script>
