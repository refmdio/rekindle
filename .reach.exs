adapter = [
  "Mix.Tasks.Rekindle.*",
  "Rekindle.Install",
  "Rekindle.Phoenix",
  "Rekindle.Phoenix.Install"
]

application = [
  "Rekindle",
  "Rekindle.Build",
  "Rekindle.Cargo",
  "Rekindle.Desktop.Builder",
  "Rekindle.Desktop.Development",
  "Rekindle.Desktop.Release",
  "Rekindle.Development.Builder",
  "Rekindle.Development.Watcher",
  "Rekindle.Doctor",
  "Rekindle.Setup",
  "Rekindle.Web.Builder",
  "Rekindle.Web.Release"
]

service = [
  "Rekindle.Cargo.Messages",
  "Rekindle.Cargo.Metadata",
  "Rekindle.Config",
  "Rekindle.Desktop.Manifest",
  "Rekindle.Development.Cleanup",
  "Rekindle.Integration",
  "Rekindle.Phoenix.Development",
  "Rekindle.Publication",
  "Rekindle.Toolchain",
  "Rekindle.Toolchain.Process",
  "Rekindle.Web.Manifest"
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
