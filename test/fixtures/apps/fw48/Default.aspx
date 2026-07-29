<%@ Page Language="C#" %>
<%--
  ASP.NET **Framework** target for the full-matrix E2E.

  Runtime-compiled on purpose. A Framework web app normally needs MSBuild web targets to publish,
  which would make this fixture depend on a Visual Studio installation on whatever machine builds
  the matrix. ASP.NET compiles .aspx on first request, so source + web.config is a complete,
  buildless app - and it exercises exactly the code path under test: the desktop CLR inside w3wp,
  where COR_ENABLE_PROFILING (not CORECLR_*) is what has to attach.

  /Default.aspx?work=1 makes an outbound request to itself so the trace has a client span as well
  as a server span, matching the Core fixture.
--%>
<script runat="server">
    protected void Page_Load(object sender, EventArgs e)
    {
        Response.ContentType = "text/plain";
        Response.Write("fw48 up on CLR " + Environment.Version + " / " +
                       System.Runtime.InteropServices.RuntimeEnvironment.GetSystemVersion() + "\n");

        if (Request.QueryString["work"] == "1")
        {
            string inner;
            try
            {
                // Same-host call: gives the profiler an HttpWebRequest client span to emit.
                var url = Request.Url.GetLeftPart(UriPartial.Authority) + Request.Path;
                var req = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(url);
                req.Timeout = 5000;
                using (var resp = req.GetResponse())
                using (var sr = new System.IO.StreamReader(resp.GetResponseStream()))
                {
                    inner = sr.ReadLine();
                }
            }
            catch (Exception ex)
            {
                inner = "inner call failed: " + ex.GetType().Name;
            }
            Response.Write("work done; inner=" + inner + "\n");
        }

        if (Request.QueryString["boom"] == "1")
        {
            throw new InvalidOperationException("boom (deliberate)");
        }
    }
</script>
