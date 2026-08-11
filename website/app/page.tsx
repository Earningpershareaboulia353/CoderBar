const features = [
  {
    number: "01",
    label: "Monitor",
    title: "Every agent, one glance away.",
    copy: "Follow live Codex and Claude sessions without leaving the app you are working in.",
    tone: "blue",
  },
  {
    number: "02",
    label: "Approve",
    title: "Unblock work from the bar.",
    copy: "Review permission requests and plans, then approve or reject them from the top of your screen.",
    tone: "lime",
  },
  {
    number: "03",
    label: "Ask",
    title: "Answer without context switching.",
    copy: "Choose an option, send a response, and let the agent continue while your flow stays intact.",
    tone: "cyan",
  },
  {
    number: "04",
    label: "Jump",
    title: "Return to the exact session.",
    copy: "Open the matching Codex, Claude, terminal, or tmux session with one click.",
    tone: "violet",
  },
];

const modes = [
  ["⌁", "Compact", "A quiet status strip that stays attached to the top edge."],
  ["▦", "Dashboard", "Projects, models, usage, tasks, and sub-agents in one surface."],
  ["?", "Decision", "Native approval, plan review, and question states."],
  ["↗", "Multi-display", "Choose the main, focused, or a specific connected display."],
];

export default function Home() {
  return (
    <main>
      <div className="ambient ambient-one" />
      <div className="ambient ambient-two" />

      <nav className="nav shell" aria-label="Main navigation">
        <a className="brand" href="#top" aria-label="CoderBar home">
          <span className="brand-mark"><span>&gt;_</span></span>
          <span>CoderBar</span>
        </a>
        <div className="nav-links">
          <a href="#features">Features</a>
          <a href="#modes">Modes</a>
          <a href="#privacy">Privacy</a>
          <a href="https://github.com/helloyulife/CoderBar">GitHub</a>
        </div>
        <a className="nav-download" href="https://github.com/helloyulife/CoderBar/releases/latest/download/CoderBar-macos.zip">
          <span className="apple">●</span> Download
        </a>
      </nav>

      <section className="hero shell" id="top">
        <div className="hero-copy">
          <div className="eyebrow"><span /> Native agent control for macOS</div>
          <h1>
            Stay in flow.
            <br />
            <em>Your agents stay close.</em>
          </h1>
          <p className="hero-lede">
            Monitor Codex and Claude, make decisions, and jump back to work —
            directly from the top of your screen.
          </p>
          <div className="hero-actions">
            <a className="button button-primary" href="https://github.com/helloyulife/CoderBar/releases/latest/download/CoderBar-macos.zip">
              Download for macOS <span>↘</span>
            </a>
            <a className="button button-quiet" href="#features">
              Explore CoderBar <span>↓</span>
            </a>
          </div>
          <p className="requirement">macOS 14+ · Apple silicon · Local-first</p>
        </div>

        <div className="hero-visual" aria-label="CoderBar product preview">
          <div className="display-frame">
            <div className="mac-strip">
              <span className="mac-left">● &nbsp; Finder &nbsp; File &nbsp; Edit &nbsp; View</span>
              <span className="mac-right">⌁ &nbsp; ◒ &nbsp; Tue 9:41</span>
            </div>
            <div className="bar-preview">
              <div className="bar-top">
                <span className="mini-app-icon">&gt;_</span>
                <b>7d</b><strong>84%</strong>
                <span className="bar-spacer" />
                <span>◖))</span><span>⚙</span>
              </div>
              <div className="session-preview">
                <div className="session-icon">&gt;_</div>
                <div className="live-rail" />
                <div className="session-copy">
                  <div className="session-title">CoderBar · Ship the release</div>
                  <div className="session-sub">You: run the final checks and prepare the build</div>
                </div>
                <div className="session-tags">
                  <span className="tag tag-blue">Codex</span>
                  <span className="tag">GPT-5.6</span>
                  <span className="tag">XHigh</span>
                  <span className="tag">2m</span>
                </div>
              </div>
              <div className="agent-steps">
                <div><i className="done">✓</i> Inspect release state <span>done</span></div>
                <div><i className="live">◆</i> Build signed macOS package <span>running</span></div>
                <div><i>○</i> Publish release notes <span>queued</span></div>
              </div>
            </div>
            <div className="desktop-card card-one"><span>MONITOR</span><b>3 sessions live</b></div>
            <div className="desktop-card card-two"><span>SUB-AGENT</span><b>Visual QA complete</b></div>
          </div>
        </div>
      </section>

      <section className="trust-strip" aria-label="Supported agents">
        <div className="shell trust-content">
          <span>WORKS WITH</span>
          <div className="agent-name"><i className="agent-dot codex" /> Codex</div>
          <div className="agent-name"><i className="agent-dot claude" /> Claude Code</div>
          <div className="agent-name"><i className="agent-dot desktop" /> Claude Desktop</div>
          <div className="agent-name muted"><i className="agent-dot more" /> More agent adapters</div>
        </div>
      </section>

      <section className="section shell" id="features">
        <div className="section-heading">
          <span className="section-kicker">01 / CORE LOOP</span>
          <h2>Four moves.<br /><em>Zero context loss.</em></h2>
          <p>CoderBar stays quiet until your agent has something worth showing.</p>
        </div>
        <div className="feature-grid">
          {features.map((feature) => (
            <article className={`feature-card ${feature.tone}`} key={feature.label}>
              <div className="feature-meta"><span>{feature.number}</span><b>{feature.label}</b></div>
              <div className="feature-glyph" aria-hidden="true">
                {feature.label === "Monitor" && <><i /><i /><i /></>}
                {feature.label === "Approve" && <span>✓</span>}
                {feature.label === "Ask" && <span>?</span>}
                {feature.label === "Jump" && <span>↗</span>}
              </div>
              <h3>{feature.title}</h3>
              <p>{feature.copy}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="product-section shell">
        <div className="product-copy">
          <span className="section-kicker">LIVE SESSION VIEW</span>
          <h2>Built around the work<br />your agents are <em>actually doing.</em></h2>
          <p>
            CoderBar reads live desktop sessions, shows real models and reasoning
            effort, follows task progress, and reveals active sub-agents.
          </p>
          <ul>
            <li><span>01</span> Live session discovery</li>
            <li><span>02</span> Task and sub-agent progress</li>
            <li><span>03</span> Usage windows and model context</li>
          </ul>
        </div>
        <div className="product-shot-wrap">
          <div className="shot-label">RUNNING ON MACOS</div>
          <img
            src="/product/coderbar-expanded.png"
            alt="CoderBar expanded session dashboard"
            className="product-shot"
          />
          <div className="shot-glow" />
        </div>
      </section>

      <section className="section shell" id="modes">
        <div className="section-heading split-heading">
          <div>
            <span className="section-kicker">02 / MODES</span>
            <h2>Small when quiet.<br /><em>Precise when needed.</em></h2>
          </div>
          <p>The interface changes shape with the state of your work — never the other way around.</p>
        </div>
        <div className="mode-grid">
          {modes.map(([glyph, title, copy]) => (
            <article className="mode-card" key={title}>
              <span className="mode-glyph">{glyph}</span>
              <h3>{title}</h3>
              <p>{copy}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="privacy-section" id="privacy">
        <div className="shell privacy-inner">
          <div className="privacy-orbit" aria-hidden="true">
            <div className="orbit orbit-one" /><div className="orbit orbit-two" />
            <div className="privacy-core">⌂</div>
          </div>
          <div className="privacy-copy">
            <span className="section-kicker">LOCAL BY DESIGN</span>
            <h2>Your agent context<br /><em>stays on your Mac.</em></h2>
            <p>
              CoderBar connects to local agent session data and local hooks. No account,
              no hosted transcript database, no extra place for your work to leak.
            </p>
            <div className="privacy-points">
              <span>● Local session discovery</span>
              <span>● Local loopback server</span>
              <span>● No telemetry layer</span>
            </div>
          </div>
        </div>
      </section>

      <section className="cta shell">
        <span className="cta-code">⌘ + SPACE FOR YOUR AGENTS</span>
        <h2>Keep the work moving.</h2>
        <p>Bring Codex and Claude into one calm, native surface.</p>
        <a className="button button-primary button-large" href="https://github.com/helloyulife/CoderBar/releases/latest/download/CoderBar-macos.zip">
          Download CoderBar <span>↘</span>
        </a>
      </section>

      <footer className="footer shell">
        <a className="brand" href="#top"><span className="brand-mark"><span>&gt;_</span></span><span>CoderBar</span></a>
        <p><a href="https://github.com/helloyulife/CoderBar">GitHub</a> · Native agent control for macOS.</p>
        <span>© 2026 CoderBar</span>
      </footer>
    </main>
  );
}
