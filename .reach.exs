adapter = [
  "Mix.Tasks.Rekindle.*",
  "Rekindle.DevServer",
  "Rekindle.Install",
  "Rekindle.Phoenix",
  "Rekindle.Phoenix.Install"
]

application = [
  "Rekindle",
  "Rekindle.Application",
  "Rekindle.Build",
  "Rekindle.Cargo",
  "Rekindle.Check",
  "Rekindle.Desktop.Builder",
  "Rekindle.Desktop.Development",
  "Rekindle.Development",
  "Rekindle.Development.Builder",
  "Rekindle.Development.Core",
  "Rekindle.Development.Watcher",
  "Rekindle.Doctor",
  "Rekindle.Setup",
  "Rekindle.Test",
  "Rekindle.Web.Builder"
]

service = [
  "Rekindle.Cargo.Messages",
  "Rekindle.Cargo.Metadata",
  "Rekindle.Config",
  "Rekindle.Desktop.Manifest",
  "Rekindle.Development.Cleanup",
  "Rekindle.Development.State",
  "Rekindle.Install.Client",
  "Rekindle.Plugin",
  "Rekindle.Plugin.Cargo",
  "Rekindle.Plugin.Cargo.Dependency",
  "Rekindle.Plugin.Egui",
  "Rekindle.Plugin.GPUI",
  "Rekindle.Plugin.Iced",
  "Rekindle.Plugin.Slint",
  "Rekindle.Plugin.Spec",
  "Rekindle.Plugin.Spec.Web",
  "Rekindle.Priv",
  "Rekindle.Publication",
  "Rekindle.Toolchain",
  "Rekindle.Toolchain.Process"
]

model = [
  "Rekindle.Build.Error",
  "Rekindle.Build.Result",
  "Rekindle.Cargo.Error",
  "Rekindle.Config.Error",
  "Rekindle.Config.Target",
  "Rekindle.Desktop.Error",
  "Rekindle.Diagnostic",
  "Rekindle.Toolchain.Check",
  "Rekindle.Toolchain.Error",
  "Rekindle.Web.Error"
]

[
  layers: [
    adapter: adapter,
    application: application,
    service: service,
    model: model
  ],
  checks: [
    layer_coverage: [
      require_all_modules: true,
      forbid_multiple_matches: true
    ]
  ],
  deps: [
    mode: :allowlist,
    allowed: [
      adapter: [:application, :service, :model],
      application: [:service, :model],
      service: [:model],
      model: []
    ]
  ],
  calls: [
    forbidden: [
      {["Mix.Tasks.Rekindle.*", "Rekindle", "Rekindle.*"], ["System.cmd", "Port.open"],
       except: ["Rekindle.Toolchain.Process"]}
    ]
  ]
]
