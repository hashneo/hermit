import {
  ApiError,
  CreateRepositoryRequest,
  CreateThreadRequest,
  RfcCatalogResponse,
  RfcDocumentView,
  RepositoryConfig,
  RepositoryListResponse,
  RepositoryValidationResult,
  ReplyThreadRequest,
  ReviewState,
  RfcDocument,
  RfcRender,
  Thread,
  ThreadListResponse,
} from "./types";

type HttpMethod = "GET" | "POST";

async function request<TResponse>(
  path: string,
  method: HttpMethod,
  body?: unknown,
): Promise<TResponse> {
  const response = await fetch(path, {
    method,
    headers: {
      "Content-Type": "application/json",
      "X-Hermit-User": "ui-demo",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  if (!response.ok) {
    let apiError: ApiError | undefined;
    try {
      apiError = (await response.json()) as ApiError;
    } catch {
      apiError = undefined;
    }
    throw new Error(apiError?.message ?? `request failed: ${response.status}`);
  }

  return (await response.json()) as TResponse;
}

export class HermitApiClient {
  constructor(private readonly baseUrl: string) {}

  private path(pathname: string): string {
    return `${this.baseUrl}${pathname}`;
  }

  createRepository(payload: CreateRepositoryRequest): Promise<RepositoryConfig> {
    return request<RepositoryConfig>(this.path("/api/v1/repositories"), "POST", payload);
  }

  listRepositories(): Promise<RepositoryListResponse> {
    return request<RepositoryListResponse>(this.path("/api/v1/repositories"), "GET");
  }

  getRepository(repositoryId: string): Promise<RepositoryConfig> {
    return request<RepositoryConfig>(this.path(`/api/v1/repositories/${repositoryId}`), "GET");
  }

  validateRepository(repositoryId: string): Promise<RepositoryValidationResult> {
    return request<RepositoryValidationResult>(
      this.path(`/api/v1/repositories/${repositoryId}/validate`),
      "POST",
    );
  }

  getRfc(repositoryId: string, prNumber: number): Promise<RfcDocument> {
    return request<RfcDocument>(
      this.path(`/api/v1/repositories/${repositoryId}/pull-requests/${prNumber}/rfc`),
      "GET",
    );
  }

  listRfcs(): Promise<RfcCatalogResponse> {
	return request<RfcCatalogResponse>(this.path("/api/v1/rfcs"), "GET");
  }

  listRepositoryRfcs(repositoryId: string): Promise<RfcCatalogResponse> {
    return request<RfcCatalogResponse>(this.path(`/api/v1/repositories/${repositoryId}/rfcs`), "GET");
  }

  getRfcById(rfcId: string): Promise<RfcDocumentView> {
	return request<RfcDocumentView>(this.path(`/api/v1/rfcs/${encodeURIComponent(rfcId)}`), "GET");
  }

  getRepositoryRfcById(repositoryId: string, rfcId: string): Promise<RfcDocumentView> {
    return request<RfcDocumentView>(
      this.path(`/api/v1/repositories/${repositoryId}/rfcs/${encodeURIComponent(rfcId)}`),
      "GET",
    );
  }

  renderRfc(repositoryId: string, prNumber: number): Promise<RfcRender> {
    return request<RfcRender>(
      this.path(`/api/v1/repositories/${repositoryId}/pull-requests/${prNumber}/rfc/render`),
      "GET",
    );
  }

  listThreads(repositoryId: string, prNumber: number): Promise<ThreadListResponse> {
    return request<ThreadListResponse>(
      this.path(`/api/v1/repositories/${repositoryId}/pull-requests/${prNumber}/threads`),
      "GET",
    );
  }

  createThread(repositoryId: string, prNumber: number, payload: CreateThreadRequest): Promise<Thread> {
    return request<Thread>(
      this.path(`/api/v1/repositories/${repositoryId}/pull-requests/${prNumber}/threads`),
      "POST",
      payload,
    );
  }

  replyThread(
    repositoryId: string,
    prNumber: number,
    threadId: string,
    payload: ReplyThreadRequest,
  ): Promise<Thread> {
    return request<Thread>(
      this.path(`/api/v1/repositories/${repositoryId}/pull-requests/${prNumber}/threads/${threadId}/reply`),
      "POST",
      payload,
    );
  }

  resolveThread(repositoryId: string, prNumber: number, threadId: string): Promise<Thread> {
    return request<Thread>(
      this.path(`/api/v1/repositories/${repositoryId}/pull-requests/${prNumber}/threads/${threadId}/resolve`),
      "POST",
    );
  }

  getReviewState(repositoryId: string, prNumber: number): Promise<ReviewState> {
    return request<ReviewState>(
      this.path(`/api/v1/repositories/${repositoryId}/pull-requests/${prNumber}/review`),
      "GET",
    );
  }

  approvePullRequest(repositoryId: string, prNumber: number, body?: string): Promise<ReviewState> {
    return request<ReviewState>(
      this.path(`/api/v1/repositories/${repositoryId}/pull-requests/${prNumber}/review/approve`),
      "POST",
      body ? { body } : {},
    );
  }
}

export const hermitApiClient = new HermitApiClient("");
