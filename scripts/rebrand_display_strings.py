#!/usr/bin/env python3
"""Curated rebrand of the app name in user-visible strings.

Deliberately NOT a blanket `"Minis" -> "Nabla"` inside every string literal. That was tried and it
corrupted three classes of literal that merely *contain* the word:

  * data paths  — `Library/MinisChat/…`, `MinisImage/`, `MinisVideo/`: renaming these in code without a
    migration orphans existing sessions, attachments and offloads.
  * URLs        — `https://github.com/OpenMinis/OpenMinis` (a real HTTP-Referer header) became
    `OpenNabla`.
  * keys/labels — notification names and log categories such as `MinisSoulMdChanged`, `MinisSymlink`.

Every entry below is a *display* string, and each is matched exactly (with an expected count) so a
change in the file fails loudly instead of silently doing nothing.
"""
from pathlib import Path

# (file, old, new, expected count)
EDITS = [
    # --- the assistant's default name (the chat header before a title is generated) is the SOUL name
    ('Agent/Session/SoulStore.swift', 'name: "Minis",', 'name: "Nabla",', 1),
    ('Agent/Session/SoulStore.swift', '    name: "Minis"\n    style: ""', '    name: "Nabla"\n    style: ""', 1),
    ('Agent/Session/SoulStore.swift', '? "Minis" : SoulStore.cachedMetadata.name', '? "Nabla" : SoulStore.cachedMetadata.name', 1),
    ('Agent/Session/SoulStore.swift', 'return n.isEmpty ? "Minis" : n', 'return n.isEmpty ? "Nabla" : n', 1),
    ('Agent/Session/SoulStore.swift', 'name = n.isEmpty ? "Minis" : n', 'name = n.isEmpty ? "Nabla" : n', 1),
    ('Agent/Session/SoulStore.swift', '/// Renders the current SOUL.md `name` (falling back to "Minis") and',
     '/// Renders the current SOUL.md `name` (falling back to the app name) and', 1),
    ('Agent/Session/SoulStore.swift', '/// any place that previously hard-coded "Minis" as a label.',
     '/// any place that previously hard-coded the app name as a label.', 1),
    ('AgentWidget/AgentLiveActivityWidget.swift', '? "Minis" : context.state.soulName', '? "Nabla" : context.state.soulName', 1),
    ('AgentWidget/AgentLiveActivityWidget.swift', '? "Minis" : state.soulName', '? "Nabla" : state.soulName', 1),
    ('Agent/Background/AgentLiveActivityManager.swift', 'return name.isEmpty ? "Minis" : name', 'return name.isEmpty ? "Nabla" : name', 1),
    ('Agent/BrowserUse/BrowserUseManager.swift', 'jobName = pageTitle.isEmpty ? "Minis" : pageTitle', 'jobName = pageTitle.isEmpty ? "Nabla" : pageTitle', 1),

    # --- the MCP OAuth client name appears on the server's own consent screen
    ('Agent/Session/MCPOAuthDiscovery.swift', '"client_name": "Minis",', '"client_name": "Nabla",', 1),

    # --- chat surfaces
    ('Views/Chat/AIChatView.swift', '? "Minis" : SoulStore.cachedMetadata.name', '? "Nabla" : SoulStore.cachedMetadata.name', 1),
    ('Views/Chat/AIChatView.swift', 'soulName = n.isEmpty ? "Minis" : n', 'soulName = n.isEmpty ? "Nabla" : n', 1),
    ('Views/ContentView.swift', '? "Minis" : SoulStore.cachedMetadata.name', '? "Nabla" : SoulStore.cachedMetadata.name', 1),
    ('Views/ContentView.swift', 'soulName = n.isEmpty ? "Minis" : n', 'soulName = n.isEmpty ? "Nabla" : n', 1),
    ('Views/ContentView.swift', 'msg.role == .user ? "User" : "Minis"', 'msg.role == .user ? "User" : "Nabla"', 1),
    ('Views/ContentView.swift', 'value: "Minis Feedback"', 'value: "Nabla Feedback"', 1),
    ('Views/Chat/AssistantBlockView.swift', 'return n.isEmpty ? "Minis" : n', 'return n.isEmpty ? "Nabla" : n', 1),
    ('Views/Chat/AssistantBlockView.swift', 'soulName = n.isEmpty ? "Minis" : n', 'soulName = n.isEmpty ? "Nabla" : n', 1),
    ('Agent/MessageList/CollectionViewMessageListV3.swift', 'soulMeta.name.isEmpty ? "Minis" : soulMeta.name', 'soulMeta.name.isEmpty ? "Nabla" : soulMeta.name', 1),
    ('Views/Chat/Voice/InlineVoiceInputView.swift', 'Text("Minis can store your transcript fixes', 'Text("Nabla can store your transcript fixes', 1),
    ('Views/Chat/AIChatView.swift', 'AppLocalized("Minis can make the Return key', 'AppLocalized("Nabla can make the Return key', 1),

    # --- agent/tool activity labels
    ('Views/Chat/ToolLiveSheet.swift', 'Text("Minis Computer")', 'Text("Nabla Computer")', 1),
    ('Views/Chat/ToolLiveSheet.swift', 'return "Minis is using Shell"', 'return "Nabla is using Shell"', 1),
    ('Views/Chat/ToolLiveSheet.swift', 'return "Minis is reading File"', 'return "Nabla is reading File"', 1),
    ('Views/Chat/ToolLiveSheet.swift', 'return "Minis is using Editor"', 'return "Nabla is using Editor"', 1),
    ('Views/Chat/ToolLiveSheet.swift', 'return "Minis is editing File"', 'return "Nabla is editing File"', 1),
    ('Views/Chat/ToolLiveSheet.swift', 'return "Minis is using Browser"', 'return "Nabla is using Browser"', 1),
    ('Views/Chat/ToolLiveSheet.swift', 'return "Minis is reading Image"', 'return "Nabla is reading Image"', 1),
    ('Views/Chat/ToolLiveSheet.swift', 'return "Minis is using Memory"', 'return "Nabla is using Memory"', 1),
    ('Views/Chat/ToolLiveSheet.swift', 'return "Minis is using an Agent"', 'return "Nabla is using an Agent"', 1),
    ('Views/Chat/ToolLiveSheet.swift', 'case .info: return "Minis"', 'case .info: return "Nabla"', 1),
    ('Views/Chat/ToolLiveSheet.swift', 'case .text: return "Minis"', 'case .text: return "Nabla"', 1),
    ('Views/Chat/ToolLiveSheet.swift', 'case .thinking: return "Minis"', 'case .thinking: return "Nabla"', 1),
    ('Views/Chat/ToolLiveSheet.swift', 'Text("Minis is browsing")', 'Text("Nabla is browsing")', 0),
    ('Agent/BrowserUse/BrowserSheetView.swift', 'Text("Minis is browsing")', 'Text("Nabla is browsing")', 1),
    ('Views/Chat/PrintHelper.swift', 'jobName.isEmpty ? "Minis" : jobName', 'jobName.isEmpty ? "Nabla" : jobName', 1),

    # --- intents (shortcut run dialogs / notifications)
    ('Agent/Intents/SendPromptIntent.swift', 'AppLocalized("Minis ', 'AppLocalized("Nabla ', 5),
    ('Agent/Jobs/HelperRunner.swift', 'AppLocalized("Minis agent")', 'AppLocalized("Nabla agent")', 1),
    ('Agent/Jobs/ScheduledJobRunner.swift', 'AppLocalized("Minis agent")', 'AppLocalized("Nabla agent")', 1),
    ('Agent/Jobs/ScheduledJobRunner.swift', 'AppLocalized("Minis scheduled task")', 'AppLocalized("Nabla scheduled task")', 1),

    # --- settings / branding surfaces
    ('Views/Settings/AboutView.swift', 'Text("Minis")', 'Text("Nabla")', 1),
    ('Views/Settings/AboutView.swift', 'Text("Minis is Your Fully Local', 'Text("Nabla is Your Fully Local', 1),
    ('Views/Settings/AppLockOverlay.swift', 'Text("Minis is Locked")', 'Text("Nabla is Locked")', 1),
    ('Views/Settings/StorageManagementView.swift', 'Section("Minis Files")', 'Section("Nabla Files")', 1),
    ('Views/Settings/SoulSettingsView.swift', 'TextField("Minis", text: $name)', 'TextField("Nabla", text: $name)', 1),
    ('Views/Settings/SoulSettingsView.swift', 'Text(name.isEmpty ? "Minis" : name)', 'Text(name.isEmpty ? "Nabla" : name)', 1),
    ('Views/Skills/SkillsManagementView.swift', 'AppLocalized("Minis Skills")', 'AppLocalized("Nabla Skills")', 1),
    ('Views/Skills/SkillsManagementView.swift', '.navigationTitle("Minis Skills")', '.navigationTitle("Nabla Skills")', 1),
    ('Views/Rootfs/ISHTerminalView.swift', '.navigationTitle("Minis Shell")', '.navigationTitle("Nabla Shell")', 1),
    ('Views/Providers/AddProviderView.swift', 'Text("Minis does not operate any server', 'Text("Nabla does not operate any server', 1),
    ('Views/MCP/MCPFormSheet.swift', 'AppLocalized("Minis will find this service', 'AppLocalized("Nabla will find this service', 1),
    ('Views/Chat/WebLoadError.swift', 'AppLocalized("Minis can’t', 'AppLocalized("Nabla can’t', 5),
    ('MinisApp.swift', 'displayName: "Minis"', 'displayName: "Nabla"', 1),
    ('FileProvider/FileProviderItem.swift', 'return "Minis"', 'return "Nabla"', 1),

    # --- outbound app-identity headers (NOT the referer URL, which points at the real repo)
    ('Providers/LLMProviderFactory.swift', '"X-Title": "Minis App"', '"X-Title": "Nabla App"', 1),
    ('Agent/Chat/AIChatViewModel+ProviderFactory.swift', '"X-Title": "Minis App"', '"X-Title": "Nabla App"', 1),
    ('Providers/OpenRouter/OpenRouterModelsAPI.swift', 'setValue("Minis App", forHTTPHeaderField: "X-Title")',
     'setValue("Nabla App", forHTTPHeaderField: "X-Title")', 1),
    ('Providers/OpenRouter/OAuth/OpenRouterOAuthManager.swift', 'setValue("Minis App", forHTTPHeaderField: "X-Title")',
     'setValue("Nabla App", forHTTPHeaderField: "X-Title")', 1),
    ('Providers/Voice/VoiceProvider+Vendors.swift', 'setValue("Minis App", forHTTPHeaderField: "X-Title")',
     'setValue("Nabla App", forHTTPHeaderField: "X-Title")', 1),
]

applied = skipped = 0
for path, old, new, expect in EDITS:
    p = Path(path)
    if not p.exists():
        print(f"  MISSING FILE {path}"); continue
    t = p.read_text()
    c = t.count(old)
    if c == 0 and expect == 0:
        continue                     # explicitly optional
    if c != expect:
        raise SystemExit(f"!! {path}: expected {expect} of {old[:60]!r}, found {c}")
    p.write_text(t.replace(old, new))
    applied += 1

print(f"applied {applied} curated rebrand edit(s)")
