using System;
using System.Collections.Generic;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.Geometry;
using Autodesk.AutoCAD.EditorInput;
using Newtonsoft.Json;

namespace AutoCadController.Commands
{
    // Simple DTOs for export
    public class ExportEntity
    {
        public string type;
        public object data;
    }

    public class LineDto { public double x1, y1, x2, y2; }
    public class ArcDto { public double cx, cy, radius, startAngle, endAngle; }
    public class PolylineDto { public List<double[]> points = new List<double[]>(); }
    public class TextDto { public string text; public double x, y; }

    public class Exporter
    {
        private Document _doc;
        public Exporter(Document doc) { _doc = doc; }

        public string ExportModelSpaceToJson()
        {
            var list = new List<ExportEntity>();
            Database db = _doc.Database;

            using (Transaction tr = db.TransactionManager.StartTransaction())
            {
                BlockTable bt = (BlockTable)tr.GetObject(db.BlockTableId, OpenMode.ForRead);
                BlockTableRecord ms = (BlockTableRecord)tr.GetObject(bt[BlockTableRecord.ModelSpace], OpenMode.ForRead);

                foreach (ObjectId id in ms)
                {
                    Entity ent = tr.GetObject(id, OpenMode.ForRead) as Entity;
                    if (ent == null) continue;

                    if (ent is Line line)
                    {
                        var dto = new LineDto
                        {
                            x1 = line.StartPoint.X,
                            y1 = line.StartPoint.Y,
                            x2 = line.EndPoint.X,
                            y2 = line.EndPoint.Y
                        };
                        list.Add(new ExportEntity { type = "line", data = dto });
                    }
                    else if (ent is Arc arc)
                    {
                        var dto = new ArcDto
                        {
                            cx = arc.Center.X,
                            cy = arc.Center.Y,
                            radius = arc.Radius,
                            startAngle = arc.StartAngle,
                            endAngle = arc.EndAngle
                        };
                        list.Add(new ExportEntity { type = "arc", data = dto });
                    }
                    else if (ent is Polyline pl)
                    {
                        var dto = new PolylineDto();
                        for (int i = 0; i < pl.NumberOfVertices; i++)
                        {
                            var p = pl.GetPoint2dAt(i);
                            dto.points.Add(new double[] { p.X, p.Y });
                        }
                        list.Add(new ExportEntity { type = "polyline", data = dto });
                    }
                    else if (ent is DBText txt)
                    {
                        var dto = new TextDto
                        {
                            text = txt.TextString,
                            x = txt.Position.X,
                            y = txt.Position.Y
                        };
                        list.Add(new ExportEntity { type = "text", data = dto });
                    }
                    else if (ent is MText mtxt)
                    {
                        var dto = new TextDto
                        {
                            text = mtxt.Text,
                            x = mtxt.Location.X,
                            y = mtxt.Location.Y
                        };
                        list.Add(new ExportEntity { type = "text", data = dto });
                    }
                    // Add other entity types as needed (Ellipse, Spline, Hatch)
                }

                tr.Commit();
            }

            var exportPackage = new
            {
                metadata = new { source = "AutoCAD", timestamp = DateTime.UtcNow },
                entities = list
            };

            return JsonConvert.SerializeObject(exportPackage, Formatting.Indented);
        }
    }
}
