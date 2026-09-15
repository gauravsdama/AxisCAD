import { FormEvent, useMemo, useState } from "react";
import { applyPrompt, editFeature, initialDocument, type DocumentState } from "./domain";

const featureIcon = { sketch: "◇", pad: "▰", pocket: "○", fillet: "◜", pattern: "✣" };

function Viewport({ document, selectedId }: { document: DocumentState; selectedId: string }) {
  const accent = document.features.find((feature) => feature.id === selectedId)?.kind === "pocket";
  return <section className="viewport" aria-label="3D CAD viewport">
    <div className="viewport-top"><span>Perspective</span><span>Millimeters</span><span>Revision {document.revision}</span></div>
    <div className="axis"><i>Y</i><b>Z</b><em>X</em></div>
    <svg className="model" viewBox="0 0 620 410" role="img" aria-label="Parametric wall bracket preview">
      <defs><linearGradient id="steel" x1="0" x2="1"><stop stopColor="#b9c5c3"/><stop offset=".55" stopColor="#eff9f4"/><stop offset="1" stopColor="#829494"/></linearGradient></defs>
      <path d="M170 124 376 63l140 80-209 67Z" fill="url(#steel)" stroke="#f1fffa" strokeWidth="2"/>
      <path d="M170 124v146l137 78V208Z" fill="#78908e" stroke="#d5eee5" strokeWidth="2"/>
      <path d="m307 208 209-65v143L307 348Z" fill="#9eb2ae" stroke="#d5eee5" strokeWidth="2"/>
      <ellipse cx="250" cy="162" rx="19" ry="10" fill="#1a2224" stroke={accent ? "#74f6bc" : "#e3faf0"} strokeWidth="5"/>
      <ellipse cx="416" cy="113" rx="19" ry="10" fill="#1a2224" stroke="#e3faf0" strokeWidth="5"/>
      <path d="M170 270 307 348 516 286" fill="none" stroke="#6df2b7" strokeDasharray="5 7" opacity=".78"/>
      <path d="M192 291h118" stroke="#e9fff5" strokeWidth="1"/><text x="227" y="312">86.0</text>
    </svg>
    <div className="viewport-footer"><span className="live"><b/>Kernel connected</span><span>FreeCAD bridge · local</span></div>
  </section>;
}

export default function App() {
  const [document, setDocument] = useState(initialDocument);
  const [selectedId, setSelectedId] = useState("pocket-holes");
  const [prompt, setPrompt] = useState("");
  const [notice, setNotice] = useState("Ready for a CAD operation");
  const selected = useMemo(() => document.features.find((feature) => feature.id === selectedId) ?? document.features[0], [document, selectedId]);

  const changeParameter = (key: string, value: number, author: "AI" | "You" = "You") => {
    setDocument((current) => editFeature(current, selected.id, key, value, author));
    setNotice(`${author} updated ${selected.name}. Revision is protected and undoable.`);
  };
  const runPrompt = (event: FormEvent) => {
    event.preventDefault();
    if (!prompt.trim()) return;
    setDocument((current) => applyPrompt(current, prompt));
    setNotice("AI plan executed through a typed CAD operation. Review the new feature receipt below.");
    setPrompt("");
  };

  return <main className="app-shell">
    <header className="appbar">
      <div className="brand"><span className="mark">A</span><strong>Axis</strong><small>CAD STUDIO</small></div>
      <nav aria-label="Main tools"><button>File</button><button>Edit</button><button>Sketch</button><button>Part</button><button>Assembly</button><button>Inspect</button><button>Drawings</button></nav>
      <div className="app-actions"><button className="quiet">⌘ S</button><button className="export">Export</button><span className="avatar">GD</span></div>
    </header>
    <div className="workspace">
      <aside className="feature-panel">
        <div className="panel-title"><span>Model</span><button aria-label="Create feature">＋</button></div>
        <div className="doc-row"><span className="cube">◈</span><span>Wall bracket</span><small>FCStd</small></div>
        <div className="tree-label">BODY 01</div>
        <div className="feature-tree">
          {document.features.map((feature) => <button key={feature.id} className={`feature ${selectedId === feature.id ? "active" : ""}`} onClick={() => setSelectedId(feature.id)}>
            <span className="feature-eye">{feature.visible ? "◉" : "○"}</span><span className="feature-icon">{featureIcon[feature.kind]}</span><span>{feature.name}</span>
          </button>)}
        </div>
        <div className="history-head"><span>Change history</span><button>↗</button></div>
        <div className="history">
          {document.operations.slice(0, 3).map((operation) => <article key={operation.id}><span className={operation.author === "AI" ? "ai-dot" : "you-dot"}/><div><strong>{operation.title}</strong><p>{operation.detail}</p><small>{operation.author} · {operation.timestamp}</small></div></article>)}
        </div>
      </aside>
      <Viewport document={document} selectedId={selectedId}/>
      <aside className="inspector">
        <div className="panel-title"><span>Properties</span><button>•••</button></div>
        <div className="selected-kind">{featureIcon[selected.kind]} {selected.kind}</div>
        <h1>{selected.name}</h1>
        <label className="text-field">Name<input value={selected.name} readOnly /></label>
        <div className="section-label">Parameters <small>mm</small></div>
        {Object.entries(selected.params).map(([key, value]) => <label className="parameter" key={key}><span>{key}</span><div><input aria-label={key} type="number" value={value} onChange={(event) => changeParameter(key, Number(event.target.value))}/><b>mm</b></div></label>)}
        <div className="inspect-card"><span>⌁</span><div><strong>Geometry valid</strong><p>0 errors · 0 interferences</p></div></div>
        <button className="measure">Measure selection</button>
      </aside>
    </div>
    <section className="ai-dock" aria-label="AI CAD assistant">
      <div className="assistant-identity"><span className="spark">✦</span><div><strong>Axis assistant</strong><small>Document-aware · local bridge connected</small></div></div>
      <form onSubmit={runPrompt}><input aria-label="Describe a CAD change" value={prompt} onChange={(event) => setPrompt(event.target.value)} placeholder="Describe a change, or select geometry first…"/><button type="submit">Run <span>↵</span></button></form>
      <div className="ai-status"><span className="pulse"/>{notice}<button>View receipt</button></div>
    </section>
  </main>;
}
