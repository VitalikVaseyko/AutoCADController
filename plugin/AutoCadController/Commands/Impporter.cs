using System;
using System.Collections.Generic;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.Geometry;
using Newtonsoft.Json;
using Autodesk.AutoCAD.EditorInput;

namespace AutoCadController.Commands
{
    // DTOs matching server response
    public class PartDto
    {
        public string type; // "cylinder", "box", "mesh"
        public double[] center; // [x,y,z]
        public double[] axis; // [x,y,z]
        public double r;
        public double h;
        public double[] dims; // [dx,dy,dz] for box
        public string mesh_obj_base64; // optional
        public Dictionary<string, object> metadata;
    }

    public class ServerResponse
    {
        public List<PartDto> parts;
        public List<object> issues;
    }

    public class Importer
    {
        private Document _doc;
        public Importer(Document doc) { _doc = doc; }

        public void ImportPartsFromJson(string json)
        {
            var response = JsonConvert.DeserializeObject<ServerResponse>(json);
            if (response == null || response.parts == null) return;

            Database db = _doc.Database;
            Editor ed = _doc.Editor;

            using (Transaction tr = db.TransactionManager.StartTransaction())
            {
                BlockTable bt = (BlockTable)tr.GetObject(db.BlockTableId, OpenMode.ForRead);
                BlockTableRecord ms = (BlockTableRecord)tr.GetObject(bt[BlockTableRecord.ModelSpace], OpenMode.ForWrite);

                foreach (var p in response.parts)
                {
                    try
                    {
                        if (p.type == "cylinder")
                        {
                            // Create a cylinder using Solid3d CreateFrustum with equal top/bottom radius
                            Solid3d s = new Solid3d();
                            s.SetDatabaseDefaults();
                            double height = p.h;
                            double radius = p.r;
                            // Create frustum: bottomRadius, topRadius => both radius => cylinder
                            s.CreateFrustum(height, radius, radius, radius);
                            // Positioning: created on UCS origin aligned on Z; apply translation
                            Vector3d centerTranslation = new Vector3d(p.center[0], p.center[1], p.center[2] - height / 2.0);
                            s.TransformBy(Matrix3d.Displacement(centerTranslation));
                            ms.AppendEntity(s);
                            tr.AddNewlyCreatedDBObject(s, true);
                        }
                        else if (p.type == "box")
                        {
                            Solid3d s = new Solid3d();
                            s.SetDatabaseDefaults();
                            double dx = p.dims?[0] ?? 10;
                            double dy = p.dims?[1] ?? 10;
                            double dz = p.dims?[2] ?? 10;
                            s.CreateBox(dx, dy, dz);
                            Vector3d centerTranslation = new Vector3d(p.center[0] - dx / 2.0, p.center[1] - dy / 2.0, p.center[2] - dz / 2.0);
                            s.TransformBy(Matrix3d.Displacement(centerTranslation));
                            ms.AppendEntity(s);
                            tr.AddNewlyCreatedDBObject(s, true);
                        }
                        else if (p.type == "mesh")
                        {
                            // For mesh, currently create a placeholder box with metadata in layer name
                            Solid3d s = new Solid3d();
                            s.SetDatabaseDefaults();
                            s.CreateBox(10, 10, 10);
                            Vector3d centerTranslation = new Vector3d(p.center[0] - 5, p.center[1] - 5, p.center[2] - 5);
                            s.TransformBy(Matrix3d.Displacement(centerTranslation));
                            ms.AppendEntity(s);
                            tr.AddNewlyCreatedDBObject(s, true);
                        }
                    }
                    catch (System.Exception ex)
                    {
                        ed.WriteMessage($"\nImport part error: {ex.Message}");
                    }
                }

                tr.Commit();
            }
        }
    }
}
