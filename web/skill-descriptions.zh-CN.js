// Local Chinese interpretations of reviewed descriptions; match source, identity and original text.
// This is dashboard copy, not a change to SKILL.md or an automatic translation service.
const SKILL_DESCRIPTION_ZH = {
  "personal|better-your-harness": {
    "original": "Audit a selected local AI Harness directory with scope-bounded evidence and an HTML report. Use for Harness health checks and agent environment optimization, not general code review. Treat static scanner observations as candidates, and verify semantic defects or runtime capabilities independently.",
    "zh": "审计指定的本地 AI 工作环境目录，基于限定范围的证据生成 HTML 报告。适合环境健康检查和智能体工作环境优化，不用于一般代码审查。静态扫描结果只是待核实线索，语义缺陷和实际运行能力需要单独验证。"
  },
  "personal|convert-markitdown": {
    "original": "Convert a user-authorized local PDF, DOCX, PPTX, XLSX, HTML, image, or other supported document to Markdown with the locally installed MarkItDown runtime. Use when downstream discussion, search, or review benefits from structured Markdown, especially for tables or mixed document formats. Do not use as a substitute for visual PDF review, source preservation, or OCR of scanned documents.",
    "zh": "使用本地 MarkItDown，将用户授权的 PDF、Word、PowerPoint、Excel、HTML、图片等文件转换为 Markdown，便于后续讨论、搜索和审阅，尤其适合表格和混合格式材料。不能替代 PDF 视觉检查、原始证据保留或扫描件 OCR。"
  },
  "personal|frontend-slides-eval": {
    "original": "Create or improve a fixed-stage 16:9 HTML slide deck for a talk, pitch, teaching session, or explicit slide presentation, using visual style previews and rendered QA. Do not use for ordinary evidence-heavy HTML reports or when a native PPTX is the required final format.",
    "zh": "创建或改进固定 16:9 画布的 HTML 幻灯片，用于演讲、提案、教学或明确的幻灯片展示，并进行样式预览与渲染检查。不适用于普通证据型 HTML 报告，也不适用于必须交付原生 PPTX 的任务。"
  },
  "personal|pm-image-to-prototype": {
    "original": "Turn user-authorized screenshots or UI images into a local interactive prototype with project-scoped design notes and visual QA. Use for image-to-UI recreation; do not use for ordinary image editing or document diagrams.",
    "zh": "将用户授权的截图或界面图片还原为本地可交互原型，附项目内设计说明与视觉验收。适合从图片复现界面，不用于普通图片编辑或文档配图。"
  },
  "personal|structured-analysis-discussion": {
    "original": "Structure open-ended, high-impact analysis or multi-source research when several plausible interpretations, stakeholder perspectives, or counterarguments could materially change a decision. Do not use for short factual answers, explicit execution, personal preferences, or deterministic small edits.",
    "zh": "当多种合理解释、利益相关方视角或反对意见可能影响决策时，组织开放性重要问题的分析与多来源研究。不用于简短事实问答、明确执行、个人偏好或结果确定的小改动。"
  },
  "personal|view-your-harness": {
    "original": "Turn an explicitly selected local directory into a read-only searchable browser for its files and Skills. Use for requests to browse, inventory, or visualize a folder or Harness; do not use for ordinary reports or to modify files.",
    "zh": "把用户明确选定的本地目录变成可搜索的只读文件与 Skill 浏览器。适合目录浏览、清点和工作环境可视化，不用于普通报告或修改文件。"
  },
  "plugin|computer-use:computer-use": {
    "original": "Control Windows apps from ChatGPT",
    "zh": "从 ChatGPT 控制 Windows 应用。"
  },
  "plugin|data-analytics:analyze-data-quality": {
    "original": "Investigate whether structured datasets and query results are trustworthy enough to use. Use for underlying data-quality risks such as freshness, grain, missingness, duplicates, broken joins, schema drift, and conflicting source results.",
    "zh": "检查结构化数据集和查询结果是否可靠，重点识别数据时效、统计粒度、缺失、重复、关联错误、结构变化及来源冲突。"
  },
  "plugin|data-analytics:build-dashboard": {
    "original": "Build or update a source-backed interactive dashboard for monitoring, exploration, and operational decisions from connected data, uploaded spreadsheets, CSVs, or other structured sources.",
    "zh": "基于已连接的数据、上传的表格、CSV 或其他结构化来源，创建或更新可追溯的交互式看板，用于监测、探索和运营决策。"
  },
  "plugin|data-analytics:build-report": {
    "original": "Build polished analytical reports for executive, product, business, or technical audiences. Use when the task needs a durable narrative answer supported by inspectable evidence.",
    "zh": "为管理、产品、业务或技术读者制作清晰完整的分析报告，适用于需要以可检查证据支撑、可长期保留的分析结论。"
  },
  "plugin|data-analytics:create-data-context": {
    "original": "Create, update, or share reusable context for analysis, reports, and dashboards, including tool preferences, look and feel, analysis practices, and data definitions. Use when asked to remember a working instruction for future tasks, save conventions, or maintain existing context.",
    "zh": "创建、更新或分享可复用的数据分析约定，包括工具偏好、界面样式、分析方法和数据定义。适用于保存后续任务的工作约定或维护已有分析上下文。"
  },
  "plugin|data-analytics:design-kpis": {
    "original": "Design KPI frameworks, metric definitions, targets, guardrails, and measurement plans for product or business decisions. Use when success metrics, drivers, guardrails, targets, or the measurement approach need to be defined or improved.",
    "zh": "设计指标体系、指标定义、目标、约束指标和衡量计划。适用于明确或改进成功标准、驱动因素及测量方法。"
  },
  "plugin|data-analytics:gather-business-context": {
    "original": "Gather business context from connected or provided sources so downstream analysis starts with the right framing. Use when an analytical question depends on missing context, such as what a metric means, what changed recently, or which sources should be checked. If the same prompt asks for diagnosis, recommendation, or a deliverable, gather context first and continue to the focused skill.",
    "zh": "从已连接或用户提供的来源补齐业务背景，例如指标含义、近期变化和应核查的来源。若任务还要求诊断、建议或交付物，应补齐背景后继续完成相应分析。"
  },
  "plugin|data-analytics:index": {
    "original": "Answer product and business questions with data and route data-related work to the right focused workflow. Use for requests involving data, metrics, trends, comparisons, drivers, KPIs, analysis, dashboards, reports, charts, tables, SQL, notebooks, spreadsheets, market sizing, data quality, reusable data context, data definitions, or working preferences, whether or not Data is at-mentioned. Dashboards can use uploaded spreadsheets, CSVs, or TSVs as source data without making the deliverable a spreadsheet. Do not use Data for general writing, editing, coding, or explanations that require none of these workflows.",
    "zh": "用数据回答产品和业务问题，并选择合适的分析工作流。覆盖指标、趋势、对比、驱动因素、看板、报告、图表、SQL、笔记本、表格、市场规模、数据质量及可复用约定；无需用户明确点名 Data。不用于与这些数据工作流无关的一般写作、编辑或编程。"
  },
  "plugin|data-analytics:jupyter-notebooks": {
    "original": "Create, edit, or validate reproducible SQL or Python notebooks. Use for notebooks, SQL/Python scratchpads, reproducible exploration, audit trails, or runnable companions where the analysis should be reviewable or rerunnable.",
    "zh": "创建、编辑和验证可复现的 SQL 或 Python 笔记本，用于探索、审计证据或可重复运行的分析过程。"
  },
  "plugin|data-analytics:kpi-reporting": {
    "original": "Prepare KPI readouts, scorecards, WBR/MBR/QBR updates, and executive summaries from quantitative business or product metrics; use when the task is to report status, compare against targets, explain validated drivers, and state operating implications.",
    "zh": "根据量化业务或产品指标制作指标简报、评分卡、周度/月度/季度业务回顾及管理摘要，说明目标差距、经验证的驱动因素和运营影响。"
  },
  "plugin|data-analytics:metric-diagnostics": {
    "original": "Diagnose why a metric changed or differs from expectation. Use when the task is to identify likely drivers of a metric movement, anomaly, gap, or discrepancy.",
    "zh": "诊断指标为何变化或偏离预期，识别变化、异常、差距和不一致背后的可能驱动因素。"
  },
  "plugin|data-analytics:product-business-analysis": {
    "original": "Analyze product or business data to support a decision or recommendation. Use when a decision depends on metric-backed evidence, such as choosing a direction, prioritizing an opportunity, evaluating a change, segmenting users, sizing tradeoffs, or deciding what to do next.",
    "zh": "分析产品或业务数据以支持决策，例如选择方向、确定机会优先级、评估变更、划分用户群、比较方案或决定下一步。"
  },
  "plugin|data-analytics:validate-data": {
    "original": "Validate analysis methodology, sources, calculations, visuals, and conclusions, including report and dashboard completeness, usability, and supported repairs.",
    "zh": "核验分析方法、来源、计算、可视化和结论，包括报告与看板的完整性、可用性及有证据支持的修正。"
  },
  "plugin|data-analytics:visualize-data": {
    "original": "Design, build, revise, and verify quantitative charts and figures while authoring reports, dashboards, notebooks, and other durable artifacts. Do not use for inline chat charts.",
    "zh": "在报告、看板、笔记本等可保留产物中设计、制作、修改和验证定量图表。不用于聊天内临时图表。"
  },
  "plugin|documents:documents": {
    "original": "Create, edit, redline, and comment on `.docx`, Word, and Google Docs-targeted document artifacts inside the container, with a strict render-and-verify workflow. Use `render_docx.py` to generate page PNGs (and optional PDF) for visual QA, then iterate until layout is flawless before delivering the final document.",
    "zh": "在容器内创建、编辑、修订和批注 DOCX、Word 及面向 Google Docs 的文档。按严格的渲染与检查流程，用 render_docx.py 生成逐页图片及可选 PDF，检查版面并修正后交付。"
  },
  "plugin|openai-developers:openai-platform-api-key": {
    "original": "Use when Codex is asked to build, run, test, debug, or configure an OpenAI-backed or provider-unspecified AI app, UI, script, CLI, generator, or tool, especially requests phrased only as \"using AI\" or generators driven by forms/user input; also use for OPENAI_API_KEY or sk-proj setup. Treat this as the credential gate: inspect safely, ask reuse-vs-new before API work, and never expose plaintext.",
    "zh": "处理构建、运行、测试、调试或配置 AI 应用、界面、脚本、命令行工具与生成器时的 OpenAI 凭证准备，也适用于 OPENAI_API_KEY 配置。安全检查现有配置，先确认复用还是新建凭证，避免暴露明文。"
  },
  "plugin|pdf:pdf": {
    "original": "Read, create, inspect, render, and verify PDF files where visual layout matters, including fillable AcroForms. Use Poppler rendering plus Python tools such as reportlab, pdfplumber, and pypdf for generation and extraction.",
    "zh": "读取、创建、检查、渲染和验证注重版面的 PDF，包括可填写的 AcroForm 表单。使用 Poppler 以及 reportlab、pdfplumber、pypdf 等工具生成或提取内容。"
  },
  "plugin|plugin-management:plugin-management": {
    "original": "Discover and suggest relevant plugins, inspect app permissions and dependencies, and manage plugin connections or removal. Use when the user asks about plugins or when a task would materially benefit from an external app, account, service, or data source that available tools cannot access.",
    "zh": "发现和推荐相关插件，检查应用权限与依赖，管理连接及移除。适用于插件相关问题，或任务确需现有工具无法访问的外部应用、账号、服务或数据来源。"
  },
  "plugin|presentations:presentations": {
    "original": "Read, create or edit PowerPoint or Google Slides decks. Use for presentation, slide deck, PowerPoint, PPT, PPTX, or Google Slides requests.",
    "zh": "读取、创建或编辑 PowerPoint 与 Google Slides 演示文稿，适用于幻灯片、PPT、PPTX 等请求。"
  },
  "plugin|sites:sites-building": {
    "original": "Use Sites when the user wants a complete website built for them, such as a landing page, portfolio, dashboard, portal, tracker, hub, or internal tool, or wants to modify a website built with Sites. Do not use for development work in other web projects unless the user explicitly requests Sites.",
    "zh": "使用 Sites 创建完整网站，如落地页、作品集、看板、门户、跟踪工具或内部应用，也可修改已有 Sites 网站。其他 Web 项目的开发只有在用户明确要求 Sites 时才使用。"
  },
  "plugin|spreadsheets:spreadsheets": {
    "original": "Use skill when user requests to create, modify, analyze, visualize, or work with spreadsheet files (`.xlsx`, `.xls`, `.csv`, `.tsv`) or Google Sheets with formulas, formatting, charts, tables, and recalculation. Do not use for live controlling Microsoft Excel app or a live Excel session.",
    "zh": "创建、修改、分析、可视化或处理 XLSX、XLS、CSV、TSV 文件及 Google Sheets，覆盖公式、格式、图表、表格和重新计算。不用于实时控制已打开的 Excel 应用或会话。"
  },
  "plugin|template-creator:template-creator": {
    "original": "Create or update a reusable personal Codex artifact-template skill. Use when the user invokes $template-creator or asks in natural language to create a reusable template from a reference document, presentation, spreadsheet, Google Docs, Slides, or Sheets link, ImageGen or Product Design image, email, Slack message, or Site project, or explicitly asks to edit or update a passed artifact-template skill. Do not use for one-off creation from an existing template.",
    "zh": "把用户给定的文档、表格、幻灯片、网页、邮件、消息或图片参考转为可复用的个人 Codex 产物模板 Skill，或更新已有模板 Skill。不用于仅用现成模板制作一次性产物。"
  },
  "plugin|visualize:visualize": {
    "original": "Create visualizations and interactive tools directly in conversation. Proactively use to show how something works; explore 'what happens when', 'what changes', or 'help me understand'; compare or inspect; create simulations, maps, charts, graphs, and mockups. Use standard tools for static scientific figures.",
    "zh": "直接在对话中创建可视化与交互工具，用于解释工作原理、探索变化、比较方案，以及制作模拟、地图、图表和模型。静态科研图表应使用标准绘图工具。"
  },
  "system|imagegen": {
    "original": "Generate or edit raster images when the task benefits from AI-created bitmap visuals such as photos, illustrations, textures, sprites, mockups, or transparent-background cutouts. Use when Codex should create a brand-new image, transform an existing image, or derive visual variants from references, and the output should be a bitmap asset rather than repo-native code or vector. Do not use when the task is better handled by editing existing SVG/vector/code-native assets, extending an established icon or logo system, or building the visual directly in HTML/CSS/canvas.",
    "zh": "生成或编辑照片、插画、纹理、精灵图、样机或透明背景素材等位图，也可改造已有图片。适合需要 AI 位图的任务；已有 SVG、矢量图标、代码生成图形或可直接用 HTML/CSS/canvas 实现的视觉，应使用相应编辑方式。"
  },
  "system|openai-docs": {
    "original": "Use for Codex models/pricing, scheduled tasks, skills, settings, setup, troubleshooting, customization, automations, and self-knowledge—including 'you,' 'your,' 'this app,' or 'this coding agent' when they refer to Codex—and for OpenAI APIs/products and ChatGPT Work. Also use for model choice/migration, prompting, SDKs, Responses, Realtime, agents, evals, and Chat/Work/Codex comparisons. Do not use for generic app/software tasks that merely mention Codex.",
    "zh": "查询 Codex 的模型、价格、定时任务、Skill、设置、安装、排错、自定义、自动化及产品能力，以及 OpenAI API、ChatGPT Work 等官方信息。也涵盖模型选择与迁移、提示词、SDK、Responses、Realtime、智能体和评测。不用于只是提到 Codex 的一般软件任务。"
  },
  "system|skill-creator": {
    "original": "Create or update a Codex skill with appropriately scoped instructions and any needed supporting resources.",
    "zh": "创建或更新 Codex Skill，编写适当限定范围的说明，并补齐必要的辅助资源。"
  },
  "system|skill-installer": {
    "original": "Install Codex skills into $CODEX_HOME/skills from a curated list or a GitHub repo path. Use when a user asks to list installable skills, install a curated skill, or install a skill from another repo (including private repos).",
    "zh": "从精选列表或指定 GitHub 仓库安装 Codex Skill，也支持私有仓库；适用于列出可安装项、安装精选 Skill 或从其他仓库安装。"
  },
  "workspace|eli5-visual-explainer-eval": {
    "original": "Create a beginner-friendly, picture-first local HTML explanation of a complex module, technical choice, process, or incident. Use for ELI5-style visual explanations; do not use for ordinary reports, slide decks, or decorative illustrations.",
    "zh": "用以图为主的本地 HTML，为初学者解释复杂模块、技术选择、流程或事件。适用于通俗的视觉讲解，不用于普通报告、幻灯片或装饰插图。"
  },
  "workspace|frontend-slides-eval": {
    "original": "Create or improve a fixed-stage 16:9 HTML slide deck for a talk, pitch, teaching session, or explicit slide presentation, using visual style previews and rendered QA. Do not use for ordinary evidence-heavy HTML reports or when a native PPTX is the required final format.",
    "zh": "创建或改进固定 16:9 画布的 HTML 幻灯片，用于演讲、提案、教学或明确的幻灯片展示，并进行样式预览与渲染检查。不适用于普通证据型 HTML 报告，也不适用于必须交付原生 PPTX 的任务。"
  },
  "plugin|data-analytics:convert-to-doc": {
    "original": "Create a polished DOCX or Google Doc from an existing Data app.",
    "zh": "根据现有 Data 应用创建经过整理的 DOCX 或 Google 文档。"
  },
  "plugin|data-analytics:convert-to-slides": {
    "original": "Create a polished PowerPoint or Google Slides deck from an existing Data app.",
    "zh": "根据现有 Data 应用创建经过整理的 PowerPoint 或 Google Slides 演示文稿。"
  },
  "plugin|data-analytics:market-sizing": {
    "original": "Estimate market, segment, or opportunity size with transparent assumptions and uncertainty. Use for TAM/SAM/SOM, sizing scenarios, or comparing the scale of possible opportunities.",
    "zh": "在明确假设和不确定性的前提下估算市场、细分市场或机会规模，适用于 TAM/SAM/SOM、规模情景估算或比较潜在机会的大小。"
  },
  "plugin|data-analytics:publish-artifact-to-sites": {
    "original": "Publish an existing Data report or dashboard to Sites, automatically for web/cloud tasks or when the user requests publication.",
    "zh": "将现有 Data 报告或看板发布到 Sites；对于 Web/云端任务或用户明确要求发布的场景自动使用。"
  },
  "plugin|data-analytics:report-to-pdf": {
    "original": "Create a polished PDF from an existing Data dashboard or report.",
    "zh": "根据现有 Data 看板或报告创建经过整理的 PDF。"
  },
  "plugin|data-analytics:schedule-refresh-jobs": {
    "original": "Create or update recurring cloud refresh jobs for an existing Data dashboard or report, including requests to keep it up to date.",
    "zh": "为现有 Data 看板或报告创建或更新定期云端刷新任务，也适用于要求持续保持内容最新的场景。"
  },
  "plugin|data-analytics:share-artifact-summary": {
    "original": "Share or provide a concise Data dashboard, report, chart, or component summary.",
    "zh": "分享或提供 Data 看板、报告、图表或组件的简明摘要。"
  },
  "plugin|hugging-face:cli": {
    "original": "Hugging Face Hub CLI (`hf`) for downloading, uploading, and managing repositories, models, datasets, and Spaces on the Hugging Face Hub. Replaces now deprecated `huggingface-cli` command.",
    "zh": "使用 Hugging Face Hub 命令行工具 `hf` 下载、上传和管理 Hub 上的仓库、模型、数据集及 Spaces。它取代已弃用的 `huggingface-cli` 命令。"
  },
  "plugin|hugging-face:community-evals": {
    "original": "Run evaluations for Hugging Face Hub models using inspect-ai and lighteval on local hardware. Use for backend selection, local GPU evals, and choosing between vLLM / Transformers / accelerate. Not for HF Jobs orchestration, model-card PRs, .eval_results publication, or community-evals automation.",
    "zh": "在本机硬件上使用 inspect-ai 和 lighteval 评测 Hugging Face Hub 模型，可用于选择后端、执行本地 GPU 评测，以及比较 vLLM、Transformers 和 accelerate。不用于编排 HF Jobs、模型卡 PR、发布 .eval_results 或 community-evals 自动化。"
  },
  "plugin|hugging-face:datasets": {
    "original": "Use this skill for Hugging Face Dataset Viewer API workflows that fetch subset/split metadata, paginate rows, search text, apply filters, download parquet URLs, and read size or statistics.",
    "zh": "使用 Hugging Face Dataset Viewer API 获取子集/切分元数据、分页读取行、搜索文本、应用筛选、下载 Parquet 地址，并读取数据集大小或统计信息。"
  },
  "plugin|hugging-face:gradio": {
    "original": "Build Gradio web UIs and demos in Python. Use when creating or editing Gradio apps, components, event listeners, layouts, or chatbots.",
    "zh": "使用 Python 构建 Gradio 网页界面和演示应用，适用于创建或编辑 Gradio 应用、组件、事件监听器、布局或聊天机器人。"
  },
  "plugin|hugging-face:jobs": {
    "original": "This skill should be used when users want to run any workload on Hugging Face Jobs infrastructure. Covers UV scripts, Docker-based jobs, hardware selection, cost estimation, authentication with tokens, secrets management, timeout configuration, and result persistence. Designed for general-purpose compute workloads including data processing, inference, experiments, batch jobs, and any Python-based tasks. Should be invoked for tasks involving cloud compute, GPU workloads, or when users mention running jobs on Hugging Face infrastructure without local setup.",
    "zh": "当用户要在 Hugging Face Jobs 基础设施上运行工作负载时使用。涵盖 UV 脚本、基于 Docker 的任务、硬件选择、成本估算、令牌认证、密钥管理、超时设置和结果持久化。适用于数据处理、推理、实验、批处理及各类 Python 任务；涉及云端计算、GPU 工作负载，或用户希望无需本地环境即可在 Hugging Face 上运行任务时应使用。"
  },
  "plugin|hugging-face:llm-trainer": {
    "original": "This skill should be used when users want to train or fine-tune language models using TRL (Transformer Reinforcement Learning) on Hugging Face Jobs infrastructure. Covers SFT, DPO, GRPO and reward modeling training methods, plus GGUF conversion for local deployment. Includes guidance on the TRL Jobs package, UV scripts with PEP 723 format, dataset preparation and validation, hardware selection, cost estimation, Trackio monitoring, Hub authentication, and model persistence. Should be invoked for tasks involving cloud GPU training, GGUF conversion, or when users mention training on Hugging Face Jobs without local GPU setup.",
    "zh": "当用户希望在 Hugging Face Jobs 上使用 TRL（Transformer Reinforcement Learning）训练或微调语言模型时使用。涵盖 SFT、DPO、GRPO、奖励建模及面向本地部署的 GGUF 转换，并提供 TRL Jobs 包、PEP 723 格式 UV 脚本、数据集准备与验证、硬件选择、成本估算、Trackio 监控、Hub 认证和模型持久化指引。涉及云端 GPU 训练、GGUF 转换或在 Hugging Face Jobs 上使用 TRL 训练模型时应使用。"
  },
  "plugin|hugging-face:paper-publisher": {
    "original": "Publish and manage research papers on Hugging Face Hub. Supports creating paper pages, linking papers to models/datasets, claiming authorship, and generating professional markdown-based research articles.",
    "zh": "在 Hugging Face Hub 发布和管理研究论文，支持创建论文页面、关联模型或数据集、认领作者身份，以及生成专业的 Markdown 研究文章。"
  },
  "plugin|hugging-face:papers": {
    "original": "Look up and read Hugging Face paper pages in markdown, and use the papers API for structured metadata such as authors, linked models/datasets/spaces, Github repo and project page. Use when the user shares a Hugging Face paper page URL, an arXiv URL or ID, or asks to summarize, explain, or analyze an AI research paper.",
    "zh": "以 Markdown 形式查找和阅读 Hugging Face 论文页面，并通过 papers API 获取作者、关联模型/数据集、GitHub 仓库和项目页面等结构化元数据。用户提供 Hugging Face 论文页、arXiv 链接或编号，或要求总结、解释、分析 AI 研究论文时使用。"
  },
  "plugin|hugging-face:trackio": {
    "original": "Track and visualize ML training experiments with Trackio. Use when logging metrics during training (Python API), firing alerts for training diagnostics, or retrieving/analyzing logged metrics (CLI). Supports real-time dashboard visualization, alerts with webhooks, HF Space syncing, and JSON output for automation.",
    "zh": "使用 Trackio 跟踪和可视化机器学习训练实验，适用于通过 Python API 记录训练指标、触发训练诊断告警，或通过命令行读取和分析已记录指标。支持实时看板、告警、同步到 HF Space，以及供自动化使用的 JSON 输出。"
  },
  "plugin|hugging-face:transformers.js": {
    "original": "Use Transformers.js to run state-of-the-art machine learning models directly in JavaScript/TypeScript. Supports NLP (text classification, translation, summarization), computer vision (image classification, object detection), audio (speech recognition, audio classification), and multimodal tasks. Works in Node.js and browsers (with WebGPU/WASM) using pre-trained models from Hugging Face Hub.",
    "zh": "使用 Transformers.js 在 JavaScript/TypeScript 中直接运行先进的机器学习模型，支持 NLP（文本分类、翻译、摘要）、计算机视觉（图像分类、目标检测）、音频（语音识别、音频分类）和多模态任务，可在 Node.js 和浏览器中运行并使用 WebGPU/WASM 加速。"
  },
  "plugin|openai-developers:agents": {
    "original": "Build agent apps with the Agents API or Agents SDK. Use when adding tools, sessions, sandboxes, handoffs, guardrails, evals, or deployment.",
    "zh": "使用 Agents API 或 Agents SDK 构建智能体应用，适用于添加工具、会话、沙箱、交接、护栏、评测或部署能力。"
  },
  "plugin|openai-developers:build-chatgpt-app": {
    "original": "Build, scaffold, refactor, and troubleshoot ChatGPT Apps SDK applications that combine an MCP server and widget UI. Use when Codex needs to design tools, register UI resources, wire the MCP Apps bridge or ChatGPT compatibility APIs, apply Apps SDK metadata or CSP or domain settings, or produce a docs-aligned project scaffold. Prefer a docs-first workflow by invoking the openai-docs skill or OpenAI developer docs MCP tools before generating code.",
    "zh": "构建、搭建脚手架、重构和排查结合 MCP 服务器与组件界面的 ChatGPT Apps SDK 应用。适用于设计工具、注册界面资源、连接 MCP Apps 桥接或 ChatGPT 兼容 API、设置 Apps SDK 元数据、CSP 或域名，以及创建符合文档的项目骨架。生成代码前优先使用 openai-docs Skill 或 OpenAI 开发者文档工具查阅文档。"
  },
  "plugin|openai-developers:chatgpt-app-submission": {
    "original": "Inspect a ChatGPT Apps MCP server codebase and generate chatgpt-app-submission.json with app info suggestions, tool hint justifications, test cases, and negative test cases, then report review-check findings and outputSchema warnings for submission review.",
    "zh": "检查 ChatGPT Apps MCP 服务器代码库，并生成 chatgpt-app-submission.json，其中包含应用信息建议、工具提示依据、测试用例和反向测试用例；随后汇报提交审查中的检查发现及 outputSchema 警告。"
  },
  "plugin|openai-developers:openai-api-troubleshooting": {
    "original": "Use when an OpenAI API request fails and Codex needs to classify the likely cause, explain the next step, and route to the right follow-up. Covers common runtime failures such as blocked outbound network access, invalid credentials, exhausted API quota or credits, rate limits, and model, project, or organization access issues; delegate key provisioning to openai-platform-api-key and current documentation lookups to openai-docs.",
    "zh": "OpenAI API 请求失败且需要判断可能原因、说明下一步并转交合适流程时使用。涵盖出站网络受阻、凭证无效、API 配额或额度耗尽、速率限制，以及模型、项目或组织访问问题；密钥配置交由 openai-platform-api-key 处理，最新文档查询交由 openai-docs 处理。"
  },
  "plugin|openai-templates:artifact-template-analytics-dashboard": {
    "original": "Create a spreadsheet using the Analytics Dashboard template and its retained reference file. Use when the user selects or names Analytics Dashboard. Monitor acquisition, engagement, retention, revenue, and conversion funnel KPIs with charts.",
    "zh": "使用 Analytics Dashboard 模板及其保留的参考文件创建电子表格。用户选择或点名该模板时使用。通过图表监测获客、参与度、留存、收入和转化漏斗等 KPI。"
  },
  "plugin|openai-templates:artifact-template-business-review": {
    "original": "Create a presentation using the Business Review template and its retained reference file. Use when the user selects or names Business Review. Review business performance, KPIs, segment results, strategic priorities, decisions, and outlook.",
    "zh": "使用 Business Review 模板及其保留的参考文件创建演示文稿。用户选择或点名该模板时使用。回顾业务表现、KPI、分群结果、战略重点、决策和展望。"
  },
  "plugin|openai-templates:artifact-template-design-report": {
    "original": "Create a document using the Design Report template and its retained reference file. Use when the user selects or names Design Report. Produce design reports with an executive summary, key findings, implications, recommendations, and appendix.",
    "zh": "使用 Design Report 模板及其保留的参考文件创建文档。用户选择或点名该模板时使用。设计报告包含执行摘要、关键发现、影响、建议和附录。"
  },
  "plugin|openai-templates:artifact-template-experiment-analysis": {
    "original": "Create a document using the Experiment Analysis template and its retained reference file. Use when the user selects or names Experiment Analysis. Analyze experiments with hypotheses, methodology, results, interpretation, limitations, and next steps.",
    "zh": "使用 Experiment Analysis 模板及其保留的参考文件创建文档。用户选择或点名该模板时使用。按假设、方法、结果、解释、局限和后续步骤分析实验。"
  },
  "plugin|openai-templates:artifact-template-financial-budget": {
    "original": "Create a spreadsheet using the Financial Budget template and its retained reference file. Use when the user selects or names Financial Budget. Model actuals, budget and scenario forecasts, variances, cash runway, and departmental plans.",
    "zh": "使用 Financial Budget 模板及其保留的参考文件创建电子表格。用户选择或点名该模板时使用。建模实际值、预算与情景预测、差异、现金续航时间及部门计划。"
  },
  "plugin|openai-templates:artifact-template-investment-committee-memo": {
    "original": "Create a document using the Investment Committee Memo template and its retained reference file. Use when the user selects or names Investment Committee Memo. Prepare investment committee memos with the thesis, transaction details, financial analysis, risks, and recommendation.",
    "zh": "使用 Investment Committee Memo 模板及其保留的参考文件创建文档。用户选择或点名该模板时使用。备忘录涵盖投资论点、交易详情、财务分析、风险和建议。"
  },
  "plugin|openai-templates:artifact-template-legal-memorandum": {
    "original": "Create a document using the Legal Memorandum template and its retained reference file. Use when the user selects or names Legal Memorandum. Draft legal memoranda with the issue, brief answer, relevant facts, analysis, and conclusion.",
    "zh": "使用 Legal Memorandum 模板及其保留的参考文件创建文档。用户选择或点名该模板时使用。法律备忘录包括争议问题、简要答复、相关事实、分析和结论。"
  },
  "plugin|openai-templates:artifact-template-market-trends-report": {
    "original": "Create a presentation using the Market Trends Report template and its retained reference file. Use when the user selects or names Market Trends Report. Communicate market or industry trends, supporting evidence, implications, and recommended responses.",
    "zh": "使用 Market Trends Report 模板及其保留的参考文件创建演示文稿。用户选择或点名该模板时使用。呈现市场或行业趋势、支撑证据、影响和建议措施。"
  },
  "plugin|openai-templates:artifact-template-minimal-letterhead": {
    "original": "Create a document using the Minimal Letterhead template and its retained reference file. Use when the user selects or names Minimal Letterhead. Write professional business letters with sender, recipient, message, and signature fields in a minimal letterhead layout.",
    "zh": "使用 Minimal Letterhead 模板及其保留的参考文件创建文档。用户选择或点名该模板时使用。采用简洁信头版式撰写商务信函，包含发件人、收件人、正文和签名栏。"
  },
  "plugin|openai-templates:artifact-template-operating-calendar": {
    "original": "Create a spreadsheet using the Operating Calendar template and its retained reference file. Use when the user selects or names Operating Calendar. Plan annual and monthly operating milestones, campaigns, launches, deadlines, and recurring events.",
    "zh": "使用 Operating Calendar 模板及其保留的参考文件创建电子表格。用户选择或点名该模板时使用。规划年度和月度运营里程碑、营销活动、发布、截止日期及周期性事件。"
  },
  "plugin|openai-templates:artifact-template-operating-review": {
    "original": "Create a presentation using the Operating Review template and its retained reference file. Use when the user selects or names Operating Review. Run weekly operating reviews with scorecards, functional updates, risks, decisions, and action items.",
    "zh": "使用 Operating Review 模板及其保留的参考文件创建演示文稿。用户选择或点名该模板时使用。通过评分卡、职能进展、风险、决策和行动项开展周度运营回顾。"
  },
  "plugin|openai-templates:artifact-template-project-kickoff": {
    "original": "Create a presentation using the Project Kickoff template and its retained reference file. Use when the user selects or names Project Kickoff. Align teams on project goals, scope, roles, milestones, risks, and the working model.",
    "zh": "使用 Project Kickoff 模板及其保留的参考文件创建演示文稿。用户选择或点名该模板时使用。帮助团队对齐项目目标、范围、角色、里程碑、风险和协作方式。"
  },
  "plugin|openai-templates:artifact-template-project-tracker": {
    "original": "Create a spreadsheet using the Project Tracker template and its retained reference file. Use when the user selects or names Project Tracker. Manage workstreams, tasks, owners, status, priority, dates, launch pulse, and a Gantt schedule.",
    "zh": "使用 Project Tracker 模板及其保留的参考文件创建电子表格。用户选择或点名该模板时使用。管理工作流、任务、负责人、状态、优先级、日期、发布进度和甘特计划。"
  },
  "plugin|openai-templates:artifact-template-sales-pipeline": {
    "original": "Create a spreadsheet using the Sales Pipeline template and its retained reference file. Use when the user selects or names Sales Pipeline. Track opportunities, stages, owners, deal sizes, probabilities, forecasts, next steps, and risks.",
    "zh": "使用 Sales Pipeline 模板及其保留的参考文件创建电子表格。用户选择或点名该模板时使用。跟踪机会、阶段、负责人、交易规模、概率、预测、后续步骤和风险。"
  },
  "plugin|openai-templates:artifact-template-simple-dark-mode": {
    "original": "Create a presentation using the Simple Dark Mode template and its retained reference file. Use when the user selects or names Simple Dark Mode. Create clean dark-mode presentations with bold typography, simple sections, charts, and imagery.",
    "zh": "使用 Simple Dark Mode 模板及其保留的参考文件创建演示文稿。用户选择或点名该模板时使用。采用醒目字体、简洁分区、图表和图片，制作清晰的深色主题演示文稿。"
  },
  "plugin|openai-templates:artifact-template-simple-light-mode": {
    "original": "Create a presentation using the Simple Light Mode template and its retained reference file. Use when the user selects or names Simple Light Mode. Create clean light-mode presentations with spacious typography, simple sections, charts, and imagery.",
    "zh": "使用 Simple Light Mode 模板及其保留的参考文件创建演示文稿。用户选择或点名该模板时使用。采用宽松的字体布局、简洁分区、图表和图片，制作清晰的浅色主题演示文稿。"
  },
  "plugin|openai-templates:artifact-template-strategy-memorandum": {
    "original": "Create a document using the Strategy Memorandum template and its retained reference file. Use when the user selects or names Strategy Memorandum. Present strategic context, choices, rationale, risks, milestones, and a clear recommendation.",
    "zh": "使用 Strategy Memorandum 模板及其保留的参考文件创建文档。用户选择或点名该模板时使用。呈现战略背景、选项、理由、风险、里程碑和明确建议。"
  },
  "plugin|openai-templates:artifact-template-system-design": {
    "original": "Create a document using the System Design template and its retained reference file. Use when the user selects or names System Design. Document system architecture, requirements, components, data flows, APIs, tradeoffs, and operational considerations.",
    "zh": "使用 System Design 模板及其保留的参考文件创建文档。用户选择或点名该模板时使用。记录系统架构、需求、组件、数据流、API、取舍和运维考量。"
  },
  "plugin|openai-templates:artifact-template-team-alignment": {
    "original": "Create a presentation using the Team Alignment template and its retained reference file. Use when the user selects or names Team Alignment. Facilitate team offsites and planning with context, goals, priorities, decisions, and action items.",
    "zh": "使用 Team Alignment 模板及其保留的参考文件创建演示文稿。用户选择或点名该模板时使用。通过背景、目标、优先级、决策和行动项支持团队共识会议与规划。"
  },
  "plugin|openai-templates:artifact-template-three-statement-forecast": {
    "original": "Create a spreadsheet using the Three-Statement Forecast template and its retained reference file. Use when the user selects or names Three-Statement Forecast. Build an integrated income statement, balance sheet, and cash flow forecast with assumptions, checks, and an executive summary.",
    "zh": "使用 Three-Statement Forecast 模板及其保留的参考文件创建电子表格。用户选择或点名该模板时使用。建立整合的利润表、资产负债表和现金流预测，并包含假设、校验和执行摘要。"
  },
  "plugin|sites:sites-hosting": {
    "original": "Host websites with Sites. Use after `sites-building` to publish new sites and edits, for requested website publishing or deployment, or for hosting management. A project containing `.openai/hosting.json` uses Sites hosting only when the current request concerns that Site. Publishing an npm package or standalone asset is not website publishing. Honor an explicit request to use another hosting provider.",
    "zh": "使用 Sites 托管网站。创建网站或修改后需要发布、用户要求发布或部署网站，或需要管理托管时，在 sites-building 之后使用。项目含 `.openai/hosting.json` 时，只有当前请求涉及该 Site 才使用 Sites 托管。发布 npm 包或独立素材不属于网站发布；用户明确要求其他托管服务商时应遵从。"
  },
  "plugin|sites:sites-preview-troubleshooting": {
    "original": "Diagnose and recover failed supervised sites-preview sessions after sites-building. Applies only to the managed-linux execution profile, not portable previews.",
    "zh": "在 sites-building 后诊断并恢复失败的受管 Sites 预览会话。仅适用于 managed-linux 执行配置，不适用于便携式预览。"
  },
  "plugin|google-calendar:google-calendar": {
    "original": "Manage scheduling and conflicts in connected Google Calendar data. Use when the user wants to inspect calendars, compare availability, review conflicts, find a meeting room, review event notes or attachments, add or adjust reminders, place temporary holds, or draft exact create, update, reschedule, or cancel changes with timezone-aware details.",
    "zh": "管理已连接 Google 日历中的日程和冲突。适用于查看日历、比较空闲时间、检查冲突、查找会议室、查看事件备注或附件、添加或调整提醒、设置临时占位，或起草含时区信息的精确创建、更新、改期或取消变更。"
  },
  "plugin|google-calendar:google-calendar-daily-brief": {
    "original": "Build polished one-day Google Calendar briefs. Use when the user asks for today, tomorrow, or a specific date summary with an agenda, conflict flags, free windows, remaining-meeting readouts, or a calendar brief, and the Google Calendar connector is available.",
    "zh": "制作整理完善的单日 Google 日历简报。Google Calendar 连接器可用，且用户要求查看今天、明天或某日的议程、冲突提示、空闲时段、剩余会议情况或日历简报时使用。"
  },
  "plugin|google-calendar:google-calendar-free-up-time": {
    "original": "Find ways to open up meaningful free time in a connected Google Calendar. Use when the user wants to clear up their day, make room for focus time, create a longer uninterrupted block, or see the smallest set of calendar changes that would give time back.",
    "zh": "在已连接的 Google 日历中寻找腾出有效空闲时间的方法。用户想清理日程、安排专注时间、创建更长的连续时段，或了解最少需要调整哪些日程才能腾出时间时使用。"
  },
  "plugin|google-calendar:google-calendar-group-scheduler": {
    "original": "Find and rank good meeting times for multiple people using connected Google Calendar data. Use when the user wants to schedule a group meeting, compare candidate slots across several attendees, find the best compromise time, or add a room check after narrowing the attendee-compatible options.",
    "zh": "使用已连接的 Google 日历为多人寻找并排序合适的会议时间。用户要安排群组会议、比较多位参会者的候选时段、寻找折中时间，或在缩小到参会者均可的选项后再检查会议室时使用。"
  },
  "plugin|google-calendar:google-calendar-meeting-prep": {
    "original": "Build a practical meeting prep brief from a connected Google Calendar event and its nearby context. Use when the user wants to prepare for an upcoming meeting, understand what to read beforehand, pull in linked notes or docs, or get a concise brief on what the meeting appears to require.",
    "zh": "根据已连接的 Google 日历事件及相关背景制作实用的会前简报。用户要准备即将召开的会议、了解会前阅读材料、整理关联笔记或文档，或简要了解会议要求时使用。"
  },
  "plugin|google-drive:google-docs": {
    "original": "Documents-first net-new Google Docs creation plus connector-first Google Docs editing in local Codex plugin sessions, with target-document checks, connector-readback verification, and reference routing for formatting, citations, tables, and write-safety.",
    "zh": "在本地 Codex 插件会话中优先通过文档流程新建 Google Docs，并优先通过连接器编辑文档；执行目标文档检查和连接器回读验证，并按需参考格式、引用、表格和写入安全指引。"
  },
  "plugin|google-drive:google-drive": {
    "original": "Use connected Google Drive as the single entrypoint for Drive, Docs, Sheets, and Slides work. Use when the user wants to find, fetch, organize, share, export, copy, or delete Drive files, or summarize and edit Google Docs, Google Sheets, and Google Slides through one unified Google Drive plugin.",
    "zh": "将已连接的 Google Drive 作为处理 Drive、Docs、Sheets 和 Slides 的统一入口。用户要查找、获取、整理、共享、导出、复制或删除 Drive 文件，或通过统一的 Google Drive 插件总结和编辑文档、表格及幻灯片时使用。"
  },
  "plugin|google-drive:google-drive-comments": {
    "original": "Write, reply to, and resolve Google Drive comments on Docs, Sheets, Slides, and Drive files with evidence-backed location context. Use when the user asks to leave comments, review a file with comments, respond to comment threads, or resolve Drive comments.",
    "zh": "基于有证据支持的定位上下文，在 Docs、Sheets、Slides 和 Drive 文件中撰写、回复及解决评论。用户要求添加评论、审阅带评论的文件、回复评论串或解决 Drive 评论时使用。"
  },
  "plugin|google-drive:google-sheets": {
    "original": "Analyze and edit connected Google Sheets with range precision. Use when the user wants to create Google Sheets, find a spreadsheet, inspect tabs or ranges, search rows, plan formulas, create or repair charts, clean or restructure tables, write concise summaries, or make explicit cell-range updates.",
    "zh": "精确到单元格范围地分析和编辑已连接的 Google Sheets。适用于创建或查找电子表格、检查工作表或区域、搜索行、规划公式、创建或修复图表、清理或重组表格、撰写简明摘要，或明确更新指定单元格范围。"
  },
  "plugin|google-drive:google-slides": {
    "original": "Google Slides work for finding, reading, summarizing, creating, importing, visual cleanup, template migration, structural repair, and content edits in native Slides decks.",
    "zh": "处理原生 Google Slides 演示文稿的查找、阅读、总结、创建、导入、视觉整理、模板迁移、结构修复和内容编辑。"
  },
  "plugin|slack:slack": {
    "original": "Read Slack context, route to the right Slack workflow, and prepare or perform Slack writes that match the user's intent.",
    "zh": "读取 Slack 上下文，将任务分流到合适的 Slack 工作流，并按用户意图准备或执行 Slack 写入。"
  },
  "plugin|slack:slack-channel-summarization": {
    "original": "Summarize activity from one Slack channel and return a concise recap, post-ready update, or summary doc.",
    "zh": "总结单个 Slack 频道的动态，并提供简明回顾、可直接发布的更新或摘要文档。"
  },
  "plugin|slack:slack-daily-digest": {
    "original": "Create a daily Slack digest from selected channels or topics. Use when the user asks for a daily Slack recap or summary of today's Slack activity.",
    "zh": "根据选定频道或主题制作 Slack 每日摘要。用户要求每日回顾或总结当天 Slack 动态时使用。"
  },
  "plugin|slack:slack-notification-triage": {
    "original": "Triage recent Slack activity into a priority queue or task list for the user.",
    "zh": "将近期 Slack 动态整理为供用户处理的优先队列或任务清单。"
  },
  "plugin|slack:slack-outgoing-message": {
    "original": "Primary skill for composing, drafting, or refining any outbound Slack content. Use this whenever the task will require using `slack_send_message`, `slack_send_message_draft`, or `slack_create_canvas`. Use `slack` to read or analyze Slack context; use this skill to produce the final outgoing message.",
    "zh": "撰写、起草或润色任何待发送 Slack 内容的主要 Skill。任务需要调用 `slack_send_message`、`slack_send_message_draft` 或 `slack_create_canvas` 时使用。读取或分析 Slack 上下文使用 `slack`；生成最终待发内容使用本 Skill。"
  },
  "plugin|slack:slack-reply-drafting": {
    "original": "Draft Slack replies from available context. Use when the user wants help finding messages that likely need a response and preparing reply drafts.",
    "zh": "根据现有上下文起草 Slack 回复。用户希望找出可能需要回复的消息并准备回复草稿时使用。"
  },
  "plugin|spreadsheets:excel-live-control": {
    "original": "Control an open or active Microsoft Excel workbook through the ChatGPT add-in or connected session. Use when the user tags the Microsoft Excel app in Codex or follows up on an established live Excel task. Do not use for standalone spreadsheet files or Google Sheets.",
    "zh": "通过 ChatGPT 加载项或已连接会话控制当前打开或正在使用的 Microsoft Excel 工作簿。用户在 Codex 中标记 Microsoft Excel 应用，或继续已有实时 Excel 任务时使用。不用于独立电子表格文件或 Google Sheets。"
  },
  "personal|eli5-visual-explainer-eval": {
    "original": "Create a beginner-friendly, picture-first local HTML explanation of a complex module, technical choice, process, or incident. Use for ELI5-style visual explanations; do not use for ordinary reports, slide decks, or decorative illustrations.",
    "zh": "用以图为主的本地 HTML 为初学者解释复杂模块、技术选择、流程或事件。适用于通俗易懂的视觉讲解，不用于普通报告、幻灯片或装饰性插图。"
  },
  "personal|pm-url-to-prototype": {
    "original": "Recreate the interaction and layout of a user-authorized reference webpage as a local prototype, using browser inspection and visual QA. Use when a URL is supplied as a design reference; do not use to copy protected assets, credentials, or site content wholesale.",
    "zh": "通过浏览器检查和视觉验收，将用户授权的参考网页交互与布局复现为本地原型。用户提供 URL 作为设计参考时使用；不得整体复制受保护的素材、凭证或网站内容。"
  },
  "system|plugin-creator": {
    "original": "Create and scaffold plugin directories for Codex with a required `.codex-plugin/plugin.json`, optional plugin folders/files, valid manifest defaults, and personal-marketplace entries by default. Use when Codex needs to create a new personal plugin, add optional plugin structure, generate or update marketplace entries for plugin ordering and availability metadata, or update an existing local plugin during development with the CLI-driven cachebuster and reinstall flow.",
    "zh": "为 Codex 创建并搭建插件目录，包含必需的 `.codex-plugin/plugin.json`、可选插件文件与目录、有效的 manifest 默认值，并默认添加个人市场条目。适用于创建个人插件、补充可选结构、生成或更新市场排序与可用性元数据，或通过命令行缓存刷新和重装流程更新本地开发中的插件。"
  },
  "plugin|hugging-face:vision-trainer": {
    "original": "Trains and fine-tunes vision models for object detection (D-FINE, RT-DETR v2, DETR, YOLOS), image classification (timm models — MobileNetV3, MobileViT, ResNet, ViT/DINOv3 — plus any Transformers classifier), and SAM/SAM2 segmentation using Hugging Face Transformers on Hugging Face Jobs cloud GPUs. Covers COCO-format dataset preparation, Albumentations augmentation, mAP/mAR evaluation, accuracy metrics, SAM segmentation with bbox/point prompts, DiceCE loss, hardware selection, cost estimation, Trackio monitoring, and Hub persistence. Use when users mention training object detection, image classification, SAM, SAM2, segmentation, image matting, DETR, D-FINE, RT-DETR, ViT, timm, MobileNet, ResNet, bounding box models, or fine-tuning vision models on Hugging Face Jobs.",
    "zh": "使用 Hugging Face Transformers 在 Hugging Face Jobs 云端 GPU 上训练或微调视觉模型，涵盖目标检测（D-FINE、RT-DETR v2、DETR、YOLOS）、图像分类及 SAM/SAM2 分割。包括 COCO 格式数据准备、Albumentations 增强、mAP/mAR 评估、准确率指标、通过边界框/点提示进行 SAM 分割、DiceCE 损失、硬件选择、成本估算、Trackio 监控和 Hub 持久化。用户提及训练目标检测或图像分类、SAM/SAM2、分割、图像抠图、相关模型名称或在 Hugging Face Jobs 上微调时使用。"
  },
  "system|review-agent": {
    "original": "Perform a read-only, defect-first review of a specified code change and return every actionable finding. Use when another agent delegates review of uncommitted changes, a base-branch diff, a commit, or custom review instructions.",
    "zh": "只读审查指定代码变更，优先查找缺陷并返回所有可操作的问题。适用于其他智能体委托审查未提交变更、相对基线分支的差异、某个提交，或提供了自定义审查指引的场景。"
  }
};
