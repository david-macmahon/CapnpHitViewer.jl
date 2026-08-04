using Documenter, CapnpHitViewer

makedocs(
    sitename = "CapnpHitViewer.jl",
    repo = "github.com/david-macmahon/CapnpHitViewer.jl.git",
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://david-macmahon.github.io/CapnpHitViewer.jl",
    ),
    modules = [CapnpHitViewer],
    checkdocs = :none,
    pages = [
        "Home" => "index.md",
        "API" => "api.md",
    ],
)

deploydocs(
    repo = "github.com/david-macmahon/CapnpHitViewer.jl.git",
    devbranch = "master",
)
