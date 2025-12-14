FastAPI minimal local server for reconstruction.
Endpoint:
- POST /reconstruct : accepts exported JSON (from plugin) and returns a simple 3D parts JSON.

This is a rule-based placeholder: for testing integration it returns a single cylinder
if it detects an arc + line pattern, otherwise returns a box placeholder.

Extend with ML inference for real reconstruction.
"""

from fastapi import FastAPI, Request
from pydantic import BaseModel
from typing import List, Optional, Any
import uvicorn
import json
import math
import time

app = FastAPI(title="AutoCad Reconstruction Server")

class SimplePart(BaseModel):
    type: str
    center: List[float]
    axis: Optional[List[float]]
    r: Optional[float]
    h: Optional[float]
    dims: Optional[List[float]]
    metadata: Optional[dict]

class ServerResponse(BaseModel):
    parts: List[SimplePart]
    issues: List[Any] = []

@app.post("/reconstruct")
async def reconstruct(request: Request):
    payload = await request.json()
    # Very simple heuristic: if we have an arc entity, return a cylinder
    entities = payload.get("entities", [])
    found_arc = False
    for e in entities:
        if e.get("type") == "arc":
            found_arc = True
            arc = e.get("data", {})
            break

    # Simple deterministic placeholder response
    parts = []
    if found_arc:
        # center from arc data (2D) -> elevate to Z=0, arbitrary radius/height
        cx = arc.get("cx", 0.0)
        cy = arc.get("cy", 0.0)
        radius = arc.get("radius", 10.0)
        parts.append({
            "type": "cylinder",
            "center": [cx, cy, radius],
            "axis": [0.0, 0.0, 1.0],
            "r": radius,
            "h": 2 * radius,
            "metadata": {"confidence": 0.5, "rule": "arc->cylinder"}
        })
    else:
        # fallback box
        parts.append({
            "type": "box",
            "center": [0.0, 0.0, 5.0],
            "dims": [10.0, 20.0, 10.0],
            "metadata": {"confidence": 0.3, "rule": "fallback_box"}
        })

    resp = {"parts": parts, "issues": []}
    # simulate small processing time
    time.sleep(0.5)
    return resp

if __name__ == "__main__":
    uvicorn.run("main:app", host="127.0.0.1", port=5000, reload=True)
