import { useEffect, useMemo, useRef, useState } from "react";
import { hermitApiClient } from "./api/client";
import { RepositoryConfig, ReviewState, RfcCatalogItem, RfcDocumentView, ThreadListResponse } from "./api/types";

type LoadState =
  | { status: "loading" }
  | { status: "error"; message: string }
  | { status: "ready" };

type TabKey = "rfcs" | "threads" | "approvals";
const defaultPRNumber = 1;
const repositorySelectionStorageKey = "hermit:selectedRepositoryId";

type SelectionAnchor = {
  line_start: number;
  line_end: number;
  formatted_line_start: number;
  formatted_line_end: number;
  text_fingerprint: string;
  selected_text: string;
};

type SelectionQuickAction = {
  anchor: SelectionAnchor;
  x: number;
  y: number;
};

export function App() {
  const [activeTab, setActiveTab] = useState<TabKey>("rfcs");
  const [state, setState] = useState<LoadState>({ status: "loading" });
  const [catalog, setCatalog] = useState<RfcCatalogItem[]>([]);
  const [repositories, setRepositories] = useState<RepositoryConfig[]>([]);
  const [activeId, setActiveId] = useState<string>("");
  const [activeRfcItem, setActiveRfcItem] = useState<RfcCatalogItem | null>(null);
  const [document, setDocument] = useState<RfcDocumentView | null>(null);
  const [repositoryId, setRepositoryId] = useState("");
  const [repositoriesLoaded, setRepositoriesLoaded] = useState(false);
  const [threads, setThreads] = useState<ThreadListResponse | null>(null);
  const [review, setReview] = useState<ReviewState | null>(null);
  const [panelError, setPanelError] = useState<string>("");
  const [newThreadBody, setNewThreadBody] = useState("");
  const [selectionAnchor, setSelectionAnchor] = useState<SelectionAnchor | null>(null);
  const [selectionQuickAction, setSelectionQuickAction] = useState<SelectionQuickAction | null>(null);
  const [inlineCommentBody, setInlineCommentBody] = useState("");
  const [focusedThreadId, setFocusedThreadId] = useState<string | null>(null);
  const docBodyRef = useRef<HTMLDivElement | null>(null);

  const activePrNumber = activeRfcItem?.pr_number ?? defaultPRNumber;

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
      setActiveRfcItem(first);
      const view = await hermitApiClient.getRepositoryRfcById(repositoryId, first.id);
      setDocument(view);
      setSelectionAnchor(null);
      setSelectionQuickAction(null);
      setFocusedThreadId(null);
      if (first.commentable && first.pr_number) {
        await loadThreads(first.pr_number);
      } else {
        setThreads(null);
      }
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
    setActiveRfcItem(item);
    setState({ status: "loading" });
    try {
      const view = await hermitApiClient.getRepositoryRfcById(repositoryId, item.id);
      setDocument(view);
      setSelectionAnchor(null);
      setSelectionQuickAction(null);
      setFocusedThreadId(null);
      if (item.commentable && item.pr_number) {
        await loadThreads(item.pr_number);
      } else {
        setThreads(null);
      }
      setState({ status: "ready" });
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : "Failed to open RFC";
      setState({ status: "error", message });
    }
  }

  async function loadThreads(prNumber = activePrNumber) {
    if (!repositoryId) {
      setPanelError("Repository is required for thread view.");
      return;
    }
    setPanelError("");
    try {
      const response = await hermitApiClient.listThreads(repositoryId, prNumber);
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
      await hermitApiClient.resolveThread(repositoryId, activePrNumber, threadId);
      await loadThreads(activePrNumber);
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
      const created = await hermitApiClient.createThread(repositoryId, activePrNumber, {
        anchor: {
          line_start: 1,
          line_end: 1,
          text_fingerprint: "rfc-header",
          file_path: activeRfcItem?.path,
        },
        body: newThreadBody.trim(),
      });
      setNewThreadBody("");
      setFocusedThreadId(created.id);
      await loadThreads(activePrNumber);
      setPanelError("");
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : "Failed to create thread";
      setPanelError(message);
    }
  }

  async function createInlineCommentThread() {
    if (!repositoryId) {
      setPanelError("Repository is required.");
      return;
    }
    if (!activeRfcItem?.commentable || !activeRfcItem.pr_number) {
      setPanelError("Inline comments are only enabled for reviewable PR RFCs.");
      return;
    }
    if (!selectionAnchor) {
      setPanelError("Select RFC text before creating an inline comment.");
      return;
    }
    if (!inlineCommentBody.trim()) {
      setPanelError("Comment message is required.");
      return;
    }

    try {
      const created = await hermitApiClient.createThread(repositoryId, activeRfcItem.pr_number, {
        anchor: {
          line_start: selectionAnchor.line_start,
          line_end: selectionAnchor.line_end,
          formatted_line_start: selectionAnchor.formatted_line_start,
          formatted_line_end: selectionAnchor.formatted_line_end,
          text_fingerprint: selectionAnchor.text_fingerprint,
          file_path: activeRfcItem.path,
        },
        body: inlineCommentBody.trim(),
      });
      setInlineCommentBody("");
      setSelectionAnchor(null);
      setSelectionQuickAction(null);
      setFocusedThreadId(created.id);
      await loadThreads(activeRfcItem.pr_number);
      setPanelError("");
      const selection = window.getSelection();
      if (selection) {
        selection.removeAllRanges();
      }
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : "Failed to create inline thread";
      setPanelError(message);
    }
  }

  function captureSelectionAnchor() {
    if (!document || !activeRfcItem?.commentable) {
      return;
    }
    const container = docBodyRef.current;
    const selection = window.getSelection();
    if (!container || !selection || selection.isCollapsed || selection.rangeCount === 0) {
      setSelectionQuickAction(null);
      return;
    }

    const range = selection.getRangeAt(0);
    if (!container.contains(range.commonAncestorContainer)) {
      return;
    }

    const selectedText = selection.toString().trim();
    if (!selectedText) {
      setSelectionQuickAction(null);
      return;
    }

    const offsets = rangeOffsetsInContainer(container, range);
    const renderedLineStart = lineNumberAtOffset(container.innerText, offsets.start);
    const renderedLineEnd = lineNumberAtOffset(container.innerText, offsets.end);
    const anchor =
      anchorFromSelection(selectedText, document.markdown_source, container.innerText, offsets.start, offsets.end) ??
      anchorFromSelectionByTextMatch(
        selectedText,
        document.markdown_source,
        container,
        range,
        renderedLineStart,
        renderedLineEnd,
      );

    if (!anchor) {
      setPanelError("Could not map selected text to a stable markdown anchor.");
      return;
    }

    const rect = range.getBoundingClientRect();
    const bubbleX = Math.min(window.innerWidth - 64, rect.right + 14);
    const bubbleY = Math.max(80, rect.top + rect.height / 2 - 22);

    setSelectionQuickAction({
      anchor: { ...anchor, selected_text: selectedText },
      x: bubbleX,
      y: bubbleY,
    });

    setPanelError("");
  }

  function openInlineCommentComposer() {
    if (!selectionQuickAction) {
      return;
    }
    setSelectionAnchor(selectionQuickAction.anchor);
    setSelectionQuickAction(null);
  }

  const rfcThreads = useMemo(() => threads?.items ?? [], [threads]);

  const threadDecorations = useMemo(() => {
    if (!document || rfcThreads.length === 0) {
      return [] as Array<{ id: string; top: number; height: number; label: string; preview: string }>;
    }
    const totalLines = Math.max(1, document.markdown_source.split("\n").length);
    return rfcThreads.map((thread) => {
      const safeStart = Math.max(1, thread.anchor.line_start);
      const safeEnd = Math.max(safeStart, thread.anchor.line_end);
      const top = Math.min(98, Math.max(1, (safeStart / totalLines) * 100));
      const rawHeight = ((safeEnd-safeStart + 1) / totalLines) * 100;
      const height = Math.max(0.9, Math.min(28, rawHeight));
      const latestMessage = thread.messages[thread.messages.length - 1]?.body ?? "";
      return {
        id: thread.id,
        top,
        height,
        label: `Lines ${thread.anchor.formatted_line_start ?? thread.anchor.line_start}-${thread.anchor.formatted_line_end ?? thread.anchor.line_end}`,
        preview: latestMessage,
      };
    });
  }, [document, rfcThreads]);

  useEffect(() => {
    const container = docBodyRef.current;
    if (!container) {
      return;
    }

    clearThreadHighlights(container);
    if (!focusedThreadId || rfcThreads.length === 0) {
      return;
    }

    const focused = rfcThreads.find((thread) => thread.id === focusedThreadId);
    if (!focused) {
      return;
    }

    highlightThreadInDocument(container, focused.anchor.text_fingerprint);
  }, [document, focusedThreadId, rfcThreads]);

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
      void loadThreads(activePrNumber);
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
      void loadThreads(activePrNumber);
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

        <section className={`right-panel ${activeTab === "rfcs" ? "rfc-stage" : ""}`}>
          {activeTab === "rfcs" && state.status === "loading" && <p className="status">Loading RFC...</p>}
          {activeTab === "rfcs" && state.status === "error" && <p className="status error">{state.message}</p>}
          {activeTab === "rfcs" && state.status === "ready" && document && (
            <div className={`rfc-read-layout ${activeRfcItem?.commentable ? "comment-enabled" : ""}`}>
              <div className="rfc-doc-column">
                <article className="doc-card rfc-page">
                  {activeRfcItem?.commentable && threadDecorations.length > 0 && (
                    <div className="doc-inline-overlays" aria-hidden="true">
                      {threadDecorations.map((marker) => (
                        <div key={`${marker.id}-range`} className="doc-thread-range" style={{ top: `${marker.top}%`, height: `${marker.height}%` }} />
                      ))}
                      {threadDecorations.map((marker) => (
                        <button
                          key={marker.id}
                          type="button"
                          className={`doc-thread-marker ${focusedThreadId === marker.id ? "focused" : ""}`}
                          style={{ top: `${marker.top}%` }}
                          onClick={() => setFocusedThreadId(marker.id)}
                          title={`${marker.label} - ${marker.preview}`}
                          aria-label={`Open thread ${marker.id}`}
                        >
                          💬
                        </button>
                      ))}
                    </div>
                  )}
                  <div
                    ref={docBodyRef}
                    className={`doc-body ${activeRfcItem?.commentable ? "commentable" : ""}`}
                    onMouseUp={captureSelectionAnchor}
                    onKeyUp={captureSelectionAnchor}
                  >
                    <pre style={{ whiteSpace: "pre-wrap", fontFamily: "inherit" }}>{document.markdown_source}</pre>
                  </div>
                </article>
              </div>

              {activeRfcItem?.commentable && selectionQuickAction && !selectionAnchor && (
                <button
                  type="button"
                  className="selection-fab"
                  style={{ left: `${selectionQuickAction.x}px`, top: `${selectionQuickAction.y}px` }}
                  onClick={openInlineCommentComposer}
                  aria-label="Add inline comment"
                  title="Add inline comment"
                >
                  +
                </button>
              )}

              {activeRfcItem?.commentable && (
                <aside className="selection-side-panel">
                  {selectionAnchor && (
                    <div className="selection-side-card">
                      <div className="selection-side-author">Steven Taylor</div>
                        <p className="selection-side-meta">
                          Selected lines {selectionAnchor.formatted_line_start}-{selectionAnchor.formatted_line_end} (raw {selectionAnchor.line_start}-{selectionAnchor.line_end})
                        </p>
                      <blockquote>{selectionAnchor.selected_text}</blockquote>
                      <textarea
                        value={inlineCommentBody}
                        onChange={(event) => setInlineCommentBody(event.target.value)}
                        placeholder="Comment or add others with @"
                      />
                      <div className="inline-actions">
                        <button
                          type="button"
                          className="link-action"
                          onClick={() => {
                            setSelectionAnchor(null);
                            setSelectionQuickAction(null);
                            const selection = window.getSelection();
                            if (selection) {
                              selection.removeAllRanges();
                            }
                          }}
                        >
                          Cancel
                        </button>
                        <button type="button" className="menu-item dark" onClick={() => void createInlineCommentThread()}>Comment</button>
                      </div>
                    </div>
                  )}

                  <div className="thread-side-list-card">
                    <h3>Comments</h3>
                    {rfcThreads.length === 0 ? (
                      <p className="status">No comments yet. Highlight text and use + to add one.</p>
                    ) : (
                      <ul className="thread-side-list">
                        {rfcThreads.map((thread) => {
                          const latestMessage = thread.messages[thread.messages.length - 1];
                          return (
                            <li key={thread.id}>
                              <button
                                type="button"
                                className={`thread-side-item ${focusedThreadId === thread.id ? "focused" : ""}`}
                                onClick={() => setFocusedThreadId(thread.id)}
                              >
                                <div className="thread-side-head">
                                  <strong>{latestMessage?.author || "Comment"}</strong>
                                  <span className={`thread-status ${thread.status}`}>{thread.status}</span>
                                </div>
                                <p className="thread-meta">
                                  Lines {thread.anchor.formatted_line_start ?? thread.anchor.line_start}-{thread.anchor.formatted_line_end ?? thread.anchor.line_end}
                                  {thread.anchor.formatted_line_start ? ` (raw ${thread.anchor.line_start}-${thread.anchor.line_end})` : ""}
                                </p>
                                <p>{latestMessage?.body}</p>
                              </button>
                            </li>
                          );
                        })}
                      </ul>
                    )}
                  </div>
                </aside>
              )}
            </div>
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
                      <p className="thread-meta">
                        Anchor lines {thread.anchor.formatted_line_start ?? thread.anchor.line_start}-{thread.anchor.formatted_line_end ?? thread.anchor.line_end}
                        {thread.anchor.formatted_line_start ? ` (raw ${thread.anchor.line_start}-${thread.anchor.line_end})` : ""}
                      </p>
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

function anchorFromSelection(
  selectedText: string,
  markdownSource: string,
  renderedText: string,
  selectionStartOffset: number,
  selectionEndOffset: number,
) {
  const normalized = selectedText.replace(/\s+/g, " ").trim();
  if (!normalized) {
    return null;
  }

  const safeRendered = renderedText.replace(/\r\n/g, "\n");
  const renderedLineStart = safeRendered.slice(0, selectionStartOffset).split("\n").length;
  const renderedLineEnd = safeRendered.slice(0, selectionEndOffset).split("\n").length;
  const lineMap = buildRenderedToRawLineMap(safeRendered, markdownSource);
  if (lineMap.size === 0) {
    return null;
  }

  const lineStart = estimateRawLine(renderedLineStart, lineMap);
  const lineEnd = estimateRawLine(Math.max(renderedLineStart, renderedLineEnd), lineMap);

  return {
    line_start: lineStart,
    line_end: Math.max(lineStart, lineEnd),
    formatted_line_start: renderedLineStart,
    formatted_line_end: Math.max(renderedLineStart, renderedLineEnd),
    text_fingerprint: fingerprint(normalized),
  };
}

function rangeOffsetsInContainer(container: HTMLElement, range: Range): { start: number; end: number } {
  const beforeRange = range.cloneRange();
  beforeRange.selectNodeContents(container);
  beforeRange.setEnd(range.startContainer, range.startOffset);

  const beforeLength = beforeRange.toString().length;
  const selectedLength = range.toString().length;
  return {
    start: Math.max(0, beforeLength),
    end: Math.max(0, beforeLength + Math.max(0, selectedLength - 1)),
  };
}

function anchorFromSelectionByTextMatch(
  selectedText: string,
  markdownSource: string,
  container: HTMLElement,
  range: Range,
  renderedLineStart: number,
  renderedLineEnd: number,
) {
  const normalized = selectedText.replace(/\s+/g, " ").trim();
  if (!normalized) {
    return null;
  }

  const selectionRatio = selectionStartRatio(container, range);
  const normalizedSource = normalizeWithIndexMap(markdownSource);
  const normalizedNeedle = normalizeForMatch(normalized);
  if (!normalizedNeedle) {
    return null;
  }

  const candidates: Array<{ start: number; end: number; score: number }> = [];
  let searchFrom = 0;
  while (searchFrom <= normalizedSource.value.length) {
    const next = normalizedSource.value.indexOf(normalizedNeedle, searchFrom);
    if (next < 0) {
      break;
    }

    const start = normalizedSource.indexMap[next] ?? 0;
    const endIndex = next + normalizedNeedle.length - 1;
    const end = normalizedSource.indexMap[Math.max(next, endIndex)] ?? start;
    const ratio = markdownSource.length > 0 ? start / markdownSource.length : 0;
    const score = Math.abs(ratio - selectionRatio);
    candidates.push({ start, end, score });
    searchFrom = next + 1;
  }

  if (candidates.length === 0) {
    return null;
  }

  candidates.sort((a, b) => a.score - b.score);
  const best = candidates[0];

  const lineStart = markdownSource.slice(0, best.start).split("\n").length;
  const lineEnd = markdownSource.slice(0, best.end).split("\n").length;

  return {
    line_start: lineStart,
    line_end: Math.max(lineStart, lineEnd),
    formatted_line_start: renderedLineStart,
    formatted_line_end: Math.max(renderedLineStart, renderedLineEnd),
    text_fingerprint: fingerprint(normalized),
  };
}

function lineNumberAtOffset(text: string, offset: number): number {
  if (text.length === 0) {
    return 1;
  }
  const safeOffset = Math.max(0, Math.min(offset, text.length));
  return text.slice(0, safeOffset).split("\n").length;
}

function selectionStartRatio(container: HTMLElement, range: Range): number {
  const offsets = rangeOffsetsInContainer(container, range);
  const totalLength = Math.max(1, container.innerText.length);
  return Math.max(0, Math.min(1, offsets.start / totalLength));
}

function buildRenderedToRawLineMap(renderedText: string, markdownSource: string): Map<number, number> {
  const renderedLines = renderedText.split("\n");
  const rawLines = markdownSource.replace(/\r\n/g, "\n").split("\n");

  const renderedNorm = renderedLines.map((line) => normalizeLine(line));
  const rawNorm = rawLines.map((line) => normalizeLine(line));

  const n = renderedNorm.length;
  const m = rawNorm.length;
  const dp: number[][] = Array.from({ length: n + 1 }, () => Array<number>(m + 1).fill(0));

  for (let i = 1; i <= n; i += 1) {
    for (let j = 1; j <= m; j += 1) {
      if (renderedNorm[i - 1] !== "" && renderedNorm[i - 1] === rawNorm[j - 1]) {
        dp[i][j] = dp[i - 1][j - 1] + 1;
      } else {
        dp[i][j] = Math.max(dp[i - 1][j], dp[i][j - 1]);
      }
    }
  }

  const pairs: Array<{ rendered: number; raw: number }> = [];
  let i = n;
  let j = m;
  while (i > 0 && j > 0) {
    if (renderedNorm[i - 1] !== "" && renderedNorm[i - 1] === rawNorm[j - 1]) {
      pairs.push({ rendered: i, raw: j });
      i -= 1;
      j -= 1;
      continue;
    }
    if (dp[i - 1][j] >= dp[i][j - 1]) {
      i -= 1;
    } else {
      j -= 1;
    }
  }

  pairs.reverse();
  const lineMap = new Map<number, number>();
  for (const pair of pairs) {
    lineMap.set(pair.rendered, pair.raw);
  }

  return lineMap;
}

function estimateRawLine(renderedLine: number, lineMap: Map<number, number>): number {
  if (lineMap.has(renderedLine)) {
    return lineMap.get(renderedLine) ?? 1;
  }

  const mapped = Array.from(lineMap.entries()).sort((a, b) => a[0] - b[0]);
  if (mapped.length === 0) {
    return 1;
  }

  let lower: [number, number] | null = null;
  let upper: [number, number] | null = null;

  for (const entry of mapped) {
    if (entry[0] < renderedLine) {
      lower = entry;
      continue;
    }
    if (entry[0] > renderedLine) {
      upper = entry;
      break;
    }
  }

  if (lower && upper) {
    const renderedSpan = upper[0] - lower[0];
    const rawSpan = upper[1] - lower[1];
    if (renderedSpan > 0) {
      const ratio = (renderedLine - lower[0]) / renderedSpan;
      return Math.max(1, Math.round(lower[1] + rawSpan * ratio));
    }
  }

  if (lower) {
    return Math.max(1, lower[1] + (renderedLine - lower[0]));
  }
  if (upper) {
    return Math.max(1, upper[1] - (upper[0] - renderedLine));
  }

  return 1;
}

function normalizeLine(line: string): string {
  return line.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function normalizeForMatch(value: string): string {
  let out = "";
  let inSpace = false;

  for (const ch of value.toLowerCase()) {
    const isAlphaNum = /[a-z0-9]/.test(ch);
    if (isAlphaNum) {
      out += ch;
      inSpace = false;
      continue;
    }
    if (!inSpace && out.length > 0) {
      out += " ";
      inSpace = true;
    }
  }

  return out.trim();
}

function normalizeWithIndexMap(value: string): { value: string; indexMap: number[] } {
  let out = "";
  const indexMap: number[] = [];
  let inSpace = false;

  for (let i = 0; i < value.length; i += 1) {
    const ch = value[i].toLowerCase();
    const isAlphaNum = /[a-z0-9]/.test(ch);
    if (isAlphaNum) {
      out += ch;
      indexMap.push(i);
      inSpace = false;
      continue;
    }

    if (!inSpace && out.length > 0) {
      out += " ";
      indexMap.push(i);
      inSpace = true;
    }
  }

  if (out.endsWith(" ")) {
    out = out.slice(0, -1);
    indexMap.pop();
  }

  return { value: out, indexMap };
}

function fingerprint(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9\s-]/g, "").trim().replace(/\s+/g, "-").slice(0, 40);
}

function clearThreadHighlights(container: HTMLElement) {
  const highlights = container.querySelectorAll("span[data-thread-highlight='true']");
  highlights.forEach((node) => {
    const parent = node.parentNode;
    if (!parent) {
      return;
    }
    parent.replaceChild(document.createTextNode(node.textContent ?? ""), node);
    parent.normalize();
  });
}

function highlightThreadInDocument(container: HTMLElement, textFingerprint: string) {
  const query = textFingerprint.replace(/-/g, " ").trim().toLowerCase();
  if (query.length < 4) {
    return;
  }

  const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT);
  let current = walker.nextNode();
  while (current) {
    const textNode = current as Text;
    const value = textNode.nodeValue ?? "";
    const lower = value.toLowerCase();
    const idx = lower.indexOf(query);
    if (idx >= 0) {
      const matched = textNode.splitText(idx);
      matched.splitText(query.length);
      const mark = document.createElement("span");
      mark.setAttribute("data-thread-highlight", "true");
      mark.className = "thread-inline-highlight";
      mark.textContent = matched.nodeValue;
      matched.parentNode?.replaceChild(mark, matched);
      break;
    }
    current = walker.nextNode();
  }
}
