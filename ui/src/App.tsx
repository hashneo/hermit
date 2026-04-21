import { useEffect, useState } from "react";
import { hermitApiClient } from "./api/client";
import { RepositoryConfig, ReviewState, RfcCatalogItem, RfcDocumentView, ThreadListResponse } from "./api/types";

type LoadState =
  | { status: "loading" }
  | { status: "error"; message: string }
  | { status: "ready" };

type TabKey = "rfcs" | "threads" | "approvals";
const defaultPRNumber = 1;
const repositorySelectionStorageKey = "hermit:selectedRepositoryId";

export function App() {
  const [activeTab, setActiveTab] = useState<TabKey>("rfcs");
  const [state, setState] = useState<LoadState>({ status: "loading" });
  const [catalog, setCatalog] = useState<RfcCatalogItem[]>([]);
  const [repositories, setRepositories] = useState<RepositoryConfig[]>([]);
  const [activeId, setActiveId] = useState<string>("");
  const [document, setDocument] = useState<RfcDocumentView | null>(null);
  const [repositoryId, setRepositoryId] = useState("");
  const [repositoriesLoaded, setRepositoriesLoaded] = useState(false);
  const [threads, setThreads] = useState<ThreadListResponse | null>(null);
  const [review, setReview] = useState<ReviewState | null>(null);
  const [panelError, setPanelError] = useState<string>("");
  const [newThreadBody, setNewThreadBody] = useState("");

  async function loadRfcCatalog() {
    if (!repositoryId) {
      setCatalog([]);
      setActiveId("");
      setDocument(null);
      setState({ status: "ready" });
      return;
    }

    setState({ status: "loading" });
    try {
      const response = await hermitApiClient.listRepositoryRfcs(repositoryId);
      setCatalog(response.items);
      if (response.items.length === 0) {
        setActiveId("");
        setDocument(null);
        setState({ status: "ready" });
        return;
      }

      const first = response.items[0];
      setActiveId(first.id);
      const view = await hermitApiClient.getRepositoryRfcById(repositoryId, first.id);
      setDocument(view);
      setState({ status: "ready" });
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : "Failed to load RFC catalog";
      setState({ status: "error", message });
    }
  }

  useEffect(() => {
    async function bootstrap() {
      try {
        const repos = await hermitApiClient.listRepositories();
        setRepositories(repos.items);
        if (repos.total > 0) {
          const savedRepositoryId = window.localStorage.getItem(repositorySelectionStorageKey);
          const hasSavedRepository =
            savedRepositoryId !== null && repos.items.some((repository) => repository.id === savedRepositoryId);
          setRepositoryId(hasSavedRepository ? savedRepositoryId : repos.items[0].id);
        } else {
          setRepositoryId("");
        }
        setRepositoriesLoaded(true);
      } catch (error: unknown) {
        const message = error instanceof Error ? error.message : "Failed to load repositories";
        setPanelError(message);
      }
    }

    void bootstrap();
  }, []);

  useEffect(() => {
    if (!repositoriesLoaded) {
      return;
    }
    if (!repositoryId) {
      window.localStorage.removeItem(repositorySelectionStorageKey);
      return;
    }
    window.localStorage.setItem(repositorySelectionStorageKey, repositoryId);
  }, [repositoriesLoaded, repositoryId]);

  async function openRfc(item: RfcCatalogItem) {
    setActiveId(item.id);
    setState({ status: "loading" });
    try {
      const view = await hermitApiClient.getRepositoryRfcById(repositoryId, item.id);
      setDocument(view);
      setState({ status: "ready" });
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : "Failed to open RFC";
      setState({ status: "error", message });
    }
  }

  async function loadThreads() {
    if (!repositoryId) {
      setPanelError("Repository is required for thread view.");
      return;
    }
    setPanelError("");
    try {
      const response = await hermitApiClient.listThreads(repositoryId, defaultPRNumber);
      setThreads(response);
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : "Failed to load threads";
      setPanelError(message);
    }
  }

  async function resolveThread(threadId: string) {
    if (!repositoryId) {
      setPanelError("Repository is required.");
      return;
    }
    try {
      await hermitApiClient.resolveThread(repositoryId, defaultPRNumber, threadId);
      await loadThreads();
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : "Failed to resolve thread";
      setPanelError(message);
    }
  }

  async function createThread() {
    if (!repositoryId) {
      setPanelError("Repository is required.");
      return;
    }
    if (!newThreadBody.trim()) {
      setPanelError("Thread message is required.");
      return;
    }
    try {
      await hermitApiClient.createThread(repositoryId, defaultPRNumber, {
        anchor: {
          line_start: 1,
          line_end: 1,
          text_fingerprint: "rfc-header",
        },
        body: newThreadBody.trim(),
      });
      setNewThreadBody("");
      await loadThreads();
      setPanelError("");
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : "Failed to create thread";
      setPanelError(message);
    }
  }

  useEffect(() => {
    if (!repositoryId) {
      return;
    }
    void loadRfcCatalog();
  }, [repositoryId]);

  useEffect(() => {
    if (!repositoryId) {
      return;
    }
    if (activeTab === "threads") {
      void loadThreads();
      return;
    }
    if (activeTab === "approvals") {
      void loadReview();
    }
  }, [activeTab, repositoryId]);

  async function loadReview() {
    if (!repositoryId) {
      setPanelError("Repository is required for approvals.");
      return;
    }
    setPanelError("");
    try {
      const response = await hermitApiClient.getReviewState(repositoryId, defaultPRNumber);
      setReview(response);
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : "Failed to load review state";
      setPanelError(message);
    }
  }

  async function approvePR() {
    if (!repositoryId) {
      setPanelError("Repository is required for approvals.");
      return;
    }
    try {
      const response = await hermitApiClient.approvePullRequest(repositoryId, defaultPRNumber, "Approved via Hermit UI");
      setReview(response);
      setPanelError("");
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : "Failed to approve PR";
      setPanelError(message);
    }
  }

  function onTabChange(nextTab: TabKey) {
    setActiveTab(nextTab);
    if (nextTab === "threads") {
      void loadThreads();
      return;
    }
    if (nextTab === "approvals") {
      void loadReview();
    }
  }

  return (
    <div className="layout-shell">
      <header className="topbar">
        <div className="brand">Hermit</div>
        <nav className="menu">
          <button type="button" className={`menu-item ${activeTab === "rfcs" ? "active" : ""}`} onClick={() => onTabChange("rfcs")}>RFCs</button>
          <button type="button" className={`menu-item ${activeTab === "threads" ? "active" : ""}`} onClick={() => onTabChange("threads")}>Threads</button>
          <button type="button" className={`menu-item ${activeTab === "approvals" ? "active" : ""}`} onClick={() => onTabChange("approvals")}>Approvals</button>
        </nav>
      </header>

      <section className="contextbar">
        <label>
          Repository
          <select value={repositoryId} onChange={(event) => setRepositoryId(event.target.value)}>
            {repositories.length === 0 && <option value="">No configured repositories</option>}
            {repositories.map((repository) => (
              <option key={repository.id} value={repository.id}>
                {repository.owner}/{repository.name} ({repository.registry})
              </option>
            ))}
          </select>
        </label>
        <span className="context-note">
          {repositoriesLoaded
            ? "Registry and repository selection load RFC, thread, and approval context."
            : "Loading configured repositories..."}
        </span>
      </section>

      <main className="workspace">
        <aside className="left-panel">
          <h2>RFC Documents</h2>
          {catalog.length === 0 && <p className="empty">No RFC files found in docs-cms/rfcs.</p>}
          <ul className="rfc-list">
            {catalog.map((item) => (
              <li key={item.id}>
                <button
                  type="button"
                  className={`rfc-link ${activeId === item.id ? "selected" : ""}`}
                  onClick={() => openRfc(item)}
                >
                  <span className="title-row">
                    <span className="title">{item.title}</span>
                    <span className={`rfc-source source-${item.source_type}`}>{item.source_label}</span>
                  </span>
                  <span className="path">{item.path}</span>
                  <span className="rfc-meta-row">
                    {item.lifecycle_status && item.lifecycle_status !== "unknown" && (
                      <span className="rfc-chip">{item.lifecycle_status}</span>
                    )}
                    {item.commentable && <span className="rfc-chip commentable">commentable</span>}
                  </span>
                </button>
              </li>
            ))}
          </ul>
        </aside>

        <section className="right-panel">
          {activeTab === "rfcs" && state.status === "loading" && <p className="status">Loading RFC...</p>}
          {activeTab === "rfcs" && state.status === "error" && <p className="status error">{state.message}</p>}
          {activeTab === "rfcs" && state.status === "ready" && document && (
            <article className="doc-card">
              <div className="doc-body" dangerouslySetInnerHTML={{ __html: document.rendered_html }} />
            </article>
          )}
          {activeTab === "rfcs" && state.status === "ready" && !document && (
            <p className="status">Choose an RFC from the left panel.</p>
          )}

          {activeTab === "threads" && (
            <article className="doc-card">
              <header className="doc-header inline-header">
                <h1>Threads</h1>
                <button type="button" className="menu-item dark" onClick={() => void loadThreads()}>Refresh</button>
              </header>
              {panelError && <p className="status error">{panelError}</p>}
              {!threads || threads.total === 0 ? (
                <p className="status">No threads found for this repository/PR.</p>
              ) : (
                <ul className="thread-list">
                  {threads.items.map((thread) => (
                    <li key={thread.id} className="thread-item">
                      <div className="thread-head">
                        <strong>{thread.id}</strong>
                        <span className={`thread-status ${thread.status}`}>{thread.status}</span>
                      </div>
                      <p className="thread-meta">Anchor lines {thread.anchor.line_start}-{thread.anchor.line_end}</p>
                      <p>{thread.messages[thread.messages.length - 1]?.body}</p>
                      {thread.status !== "resolved" && (
                        <button type="button" className="menu-item dark" onClick={() => void resolveThread(thread.id)}>Resolve</button>
                      )}
                    </li>
                  ))}
                </ul>
              )}
              <div className="thread-create">
                <h3>Add thread</h3>
                <textarea
                  value={newThreadBody}
                  onChange={(event) => setNewThreadBody(event.target.value)}
                  placeholder="Add a comment thread for this RFC..."
                />
                <button type="button" className="menu-item dark" onClick={() => void createThread()}>Create thread</button>
              </div>
            </article>
          )}

          {activeTab === "approvals" && (
            <article className="doc-card">
              <header className="doc-header inline-header">
                <h1>Approvals</h1>
                <button type="button" className="menu-item dark" onClick={() => void loadReview()}>Refresh</button>
              </header>
              {panelError && <p className="status error">{panelError}</p>}
              {review ? (
                <div>
                  <p><strong>State:</strong> {review.state}</p>
                  <p><strong>Reviewer:</strong> {review.reviewer || "-"}</p>
                  <p><strong>Updated:</strong> {new Date(review.updated_at).toLocaleString()}</p>
                </div>
              ) : (
                <p className="status">No review state loaded yet.</p>
              )}
              <button type="button" className="menu-item dark" onClick={() => void approvePR()}>Approve PR</button>
            </article>
          )}
        </section>
      </main>
    </div>
  );
}
