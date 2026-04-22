export type ApiError = {
  code: string;
  message: string;
  details?: Record<string, unknown>;
  correlation_id: string;
};

export type ValidationCheck = {
  name: string;
  status: "pass" | "fail" | "warn";
  message?: string;
};

export type RepositoryValidationResult = {
  healthy: boolean;
  checks: ValidationCheck[];
  validated_at: string;
  last_error_code?: string;
};

export type RepositoryConfig = {
  id: string;
  owner: string;
  name: string;
  registry: string;
  default_branch: string;
  docs_path_policy: string;
  auth: {
    method: "pat";
    token_last_validated_at?: string | null;
  };
  validation: RepositoryValidationResult;
  created_at: string;
  updated_at: string;
};

export type CreateRepositoryRequest = {
  owner: string;
  name: string;
  registry?: string;
  personal_access_token: string;
  default_branch?: string;
  docs_path_policy?: string;
};

export type RepositoryListResponse = {
  items: RepositoryConfig[];
  total: number;
};

export type RfcDocument = {
  repository_id: string;
  pr_number: number;
  head_sha: string;
  file_path?: string;
  eligibility: {
    status: "eligible" | "ineligible";
    reasons: string[];
  };
};

export type Anchor = {
  anchor_id: string;
  line_start: number;
  line_end: number;
  formatted_line_start?: number;
  formatted_line_end?: number;
  text_fingerprint: string;
  file_path?: string;
};

export type RfcRender = {
  repository_id: string;
  pr_number: number;
  head_sha: string;
  rendered_html: string;
  markdown_source?: string;
  anchor_map: Anchor[];
};

export type Thread = {
  id: string;
  repository_id: string;
  pr_number: number;
  status: "open" | "resolved";
  anchor: Anchor;
  messages: Array<{
    id: string;
    author: string;
    body: string;
    source_system: "hermit" | "github";
    github_comment_id?: string;
    created_at: string;
  }>;
  github_thread_id?: string;
  sync: {
    state: "synced" | "pending" | "failed" | "reconciling";
    last_synced_at?: string;
    last_error_code?: string;
    retry_count: number;
  };
  created_at: string;
  updated_at: string;
};

export type ThreadListResponse = {
  items: Thread[];
  total: number;
};

export type CreateThreadRequest = {
  anchor: {
    line_start: number;
    line_end: number;
    formatted_line_start?: number;
    formatted_line_end?: number;
    text_fingerprint: string;
    file_path?: string;
  };
  body: string;
};

export type ReplyThreadRequest = {
  body: string;
};

export type ReviewState = {
  repository_id: string;
  pr_number: number;
  state: "approved" | "changes_requested" | "commented" | "pending";
  reviewer?: string;
  github_review_id?: string;
  updated_at: string;
};

export type RfcCatalogItem = {
  id: string;
  title: string;
  path: string;
  source_type: "main" | "pull_request";
  source_label: string;
  allowed_actions: Array<"view" | "comment">;
  lifecycle_status?: "draft" | "accepted" | "implemented" | "unknown";
  pr_number?: number;
  head_sha?: string;
  commentable: boolean;
};

export type RfcCatalogResponse = {
  items: RfcCatalogItem[];
  total: number;
};

export type RfcDocumentView = {
  id: string;
  title: string;
  path: string;
  rendered_html: string;
  markdown_source: string;
};
