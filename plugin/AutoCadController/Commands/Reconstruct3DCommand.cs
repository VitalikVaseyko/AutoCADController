using System;
using Autodesk.AutoCAD.Runtime;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.EditorInput;
using Autodesk.AutoCAD.DatabaseServices;
using Newtonsoft.Json;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;

[assembly: CommandClass(typeof(AutoCadController.Commands.Reconstruct3DCommand))]

namespace AutoCadController.Commands
{
    public class Reconstruct3DCommand
    {
        // Entry command
        [CommandMethod("RECONSTRUCT3D")]
        public void Run()
        {
            Document doc = Application.DocumentManager.MdiActiveDocument;
            Editor ed = doc.Editor;

            try
            {
                ed.WriteMessage("\nAutoCadController: Exporting 2D primitives...");

                var exporter = new Exporter(doc);
                string json = exporter.ExportModelSpaceToJson();

                // Save a local copy for debugging
                string tmpJsonPath = Path.Combine(Path.GetTempPath(), "autocad_export.json");
                File.WriteAllText(tmpJsonPath, json);

                ed.WriteMessage($"\nExport saved: {tmpJsonPath}");
                ed.WriteMessage("\nSending to local reconstruction server...");

                // Send to local server (synchronous wait for simplicity)
                var client = new HttpClient();
                var content = new StringContent(json, Encoding.UTF8, "application/json");
                var responseTask = client.PostAsync("http://127.0.0.1:5000/reconstruct", content);
                responseTask.Wait();

                var response = responseTask.Result;
                if (!response.IsSuccessStatusCode)
                {
                    ed.WriteMessage($"\nServer returned error: {response.StatusCode}");
                    return;
                }

                var readTask = response.Content.ReadAsStringAsync();
                readTask.Wait();
                string responseJson = readTask.Result;

                // Save response for debugging
                string tmpRespPath = Path.Combine(Path.GetTempPath(), "autocad_response.json");
                File.WriteAllText(tmpRespPath, responseJson);
                ed.WriteMessage($"\nResponse saved: {tmpRespPath}");

                // Import parts
                var importer = new Importer(doc);
                importer.ImportPartsFromJson(responseJson);

                ed.WriteMessage("\nAutoCadController: Completed.");
            }
            catch (System.Exception ex)
            {
                ed.WriteMessage($"\nAutoCadController Error: {ex.Message}\n{ex.StackTrace}");
            }
        }
    }
}
