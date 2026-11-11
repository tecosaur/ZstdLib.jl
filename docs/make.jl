# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

using ZstdLib
using Documenter
using Org

# Convert .org files to .md for Documenter
for (root, _, files) in walkdir(joinpath(@__DIR__, "src"))
    for f in filter(endswith(".org"), files)
        orgfile = joinpath(root, f)
        mdfile = replace(orgfile, r"\.org$" => ".md")
        read(orgfile, String) |>
            c -> Org.parse(OrgDoc, c) |>
            o -> sprint(markdown, o) |>
            s -> replace(s, r"\.org\]" => ".md]") |>
            m -> write(mdfile, m)
    end
end

makedocs(;
    modules=[ZstdLib],
    authors="TEC <git@tecosaur.net>",
    sitename="ZstdLib.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://tecosaur.github.io/ZstdLib.jl",
        edit_link="main",
    ),
    pages=[
        "Introduction" => "index.md",
        "Reading" => "reading.md",
        "Writing" => "writing.md",
        "Dictionaries" => "dictionaries.md",
    ],
    warnonly=[:missing_docs, :cross_references],
)

deploydocs(;
    repo="github.com/tecosaur/ZstdLib.jl",
    devbranch="main",
)
