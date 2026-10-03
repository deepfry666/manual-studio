export type StepName = "plan" | "prompts" | "images" | "gate" | "content" | "design" | "receipt" | "build";
export type StepStatus = "pending" | "running" | "done" | "failed" | "review" | "skipped";

export interface ImageProvider {
  id: string;
  name: string;
  enabled: boolean;
  preset: "openai-sync" | "apimart-async" | "custom";
  baseUrl: string;
  model: string;
  modelGroup: string;
  sizeMode: "pixel" | "ratio";
  pixelSize: string;
  ratios: string[];
  quality: string;
  concurrency: number;
  hardTimeoutSec: number;
  hedgeDefaultSec: number;
  mapping: unknown;
}

export interface LlmVendor {
  id: string;
  name: string;
  preset: "openai" | "deepseek" | "zhipu" | "custom";
  baseUrl: string;
  jsonMode: boolean;
  models: string[];
}

export interface Settings {
  workspaceDir: string;
  image: {
    targetSize: string;
    quality: string;
    globalConcurrency: number;
    maxAttemptsPerScreen: number;
    gateRegenerateLimit: number;
    spillover: boolean;
    hedge: { enabled: boolean; percentile: number; minSec: number; maxSec: number; maxPerBatch: number; allowCrossModel: boolean };
  };
  providers: ImageProvider[];
  llm: { vendors: LlmVendor[]; assignments: Record<string, { vendorId: string; model: string } | null> };
  pipeline: { defaultScreenCount: number; platform: string; reviewPlanSingle: boolean; reviewPlanBatch: boolean; batchConcurrency: number; featureTextFloor: number };
  txtFields: Record<string, string>;
  codeDefaults: { extensions: string[]; excludeDirs: string[] };
}

export interface SettingsBundle {
  settings: Settings;
  providerKeys: Record<string, boolean>;
  vendorKeys: Record<string, boolean>;
  presets: {
    image: Record<string, { label: string; protocol: string; sizeMode: string; pixelSize: string; ratios: string[]; concurrency: number; hardTimeoutSec: number; hedgeDefaultSec: number; mapping: unknown }>;
    llm: Record<string, { label: string; baseUrl: string; jsonMode: boolean; vision: boolean; suggestedModels: string[] }>;
  };
  llmSteps: Record<string, { label: string; needsVision: boolean }>;
  steps: StepName[];
  stepLabels: Record<StepName, string>;
}

export interface ProviderStatus {
  calls: number;
  successRate: number | null;
  p50: number | null;
  p85: number | null;
  p90: number | null;
  lastError: string | null;
  lastAt: string | null;
  unavailable: string | null;
  hedgeThresholdSec: number;
}

export interface ProjectSummary {
  dir: string;
  name: string;
  origin: "created" | "imported";
  grade: "ready" | "needs-gate" | "readonly" | null;
  readOnly: boolean;
  status: string;
  steps: Record<StepName, StepStatus>;
  screens: number;
  hasCodeSource: boolean;
  lastBuildAt: string | null;
  lastError: string | null;
  warnings: number;
  addedAt: string;
  updatedAt: string;
}

export interface GateInfo {
  status: "passed" | "manual-passed" | "failed" | "needs-manual" | "error";
  method: string;
  reasons?: string[];
  warnings?: string[];
  inventory?: string;
  visibleText?: string[];
  checkedAt?: string;
}

export interface ScreenState {
  promptEdited?: boolean;
  providerId?: string;
  providerName?: string;
  model?: string;
  hedged?: boolean;
  width?: number;
  height?: number;
  imageWarnings?: string[];
  generatedAt?: string;
  textEdited?: boolean;
  gate?: GateInfo | null;
}

export interface PlanScreen {
  id: string;
  title: string;
  pageType?: string;
  activeTab?: string | null;
  mustShow?: string[];
  sampleData?: string[];
  visualBrief?: string;
  textContract?: { entry: string; action: string; feedback: string; exception: string; exit: string };
}

export interface ProjectRequest {
  softwareName: string;
  versionPolicy: string;
  applicableVersion: string;
  screenCount: number | null;
  emphasis: string;
  notes: string;
  platform: string;
  wantDesign: boolean;
  codeSource: { path: string; extensions: string[] } | null;
  txtFields: Record<string, string> | null;
  extraBrandTokens: string[];
  compileDate: string;
  createdAt: string;
  allowDropCodeDoc?: boolean;
}

export interface ProjectState {
  request: ProjectRequest;
  status: string;
  steps: Record<StepName, { status: StepStatus; error?: string | null; message?: string | null; finishedAt?: string }>;
  screens: Record<string, ScreenState>;
  warnings: string[];
  log: { at: string; level: string; message: string }[];
  origin: string;
  readOnly?: boolean;
  imported?: { grade: string };
  lastError?: string | null;
  lastBuild?: { at: string; files: string[]; withPdf: boolean; withCode: boolean; code: { fileCount: number; lineCount: number; estimatedPages: number } | null; pdfPages: number | null; warnings: string[] };
}

export interface ProjectDetail {
  dir: string;
  state: ProjectState;
  plan: { profile: { domain: string; targetUser: string; coreFlow: string } | null; featureMap: { coverageReason?: string } | null; screens: PlanScreen[]; uiContract: Record<string, unknown> | null } | null;
  content: { cover: { overview: string }; screens: { id: string; title: string; caption: string; text: string }[]; design?: { sections: { title: string; text: string }[] } } | null;
  screens: { id: string; file: string | null; mtime: number | null; prompt: string; state: ScreenState; alternates: { file: string; name: string }[]; plan: PlanScreen | null }[];
  bundleDir: string;
  bundleFiles: string[];
  running: boolean;
}

export interface CallRow {
  ts: string;
  projectName?: string;
  projectDir?: string;
  screenId?: string;
  providerId: string;
  providerName?: string;
  model?: string;
  role?: string;
  ok: boolean;
  kind?: string;
  outcome?: string;
  durationMs?: number;
  requestSize?: string;
  errorMessage?: string;
  hedged?: boolean;
  step?: string;
  vendorId?: string;
}

export interface BatchItem {
  id: string;
  projectDir: string;
  batchId: string;
  status: "queued" | "running" | "done" | "failed" | "needs-attention" | "paused";
  addedAt: string;
  startedAt?: string;
  finishedAt?: string;
  error?: string | null;
}

export interface StudioEvent {
  type: string;
  projectDir?: string;
  [key: string]: unknown;
}
