// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import SwiftUI
import NESWallpaperCore

struct TASBrowserView: View {
    @ObservedObject var model: TASBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.moviesDirSet {
                notice("Set a Movies folder in Settings to download runs.")
                Divider()
            }
            if case .failed(let message) = model.catalogState, !model.publications.isEmpty {
                notice("Could not refresh the catalog: \(message)")
                Divider()
            }
            content
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 400)
        .onAppear { model.onAppear() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search runs", text: $model.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 280)

            Spacer()

            if case .loaded(let fetchedAt) = model.catalogState {
                Text("\(model.filtered.count) runs · updated \(fetchedAt, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.catalogState == .loading {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Refresh") { model.refresh() }
                .disabled(model.catalogState == .loading)
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        if model.publications.isEmpty {
            switch model.catalogState {
            case .failed(let message):
                centered {
                    VStack(spacing: 8) {
                        Text("Could Not Load the TASVideos Catalog")
                            .font(.headline)
                        Text(message)
                            .foregroundStyle(.secondary)
                        Button("Try Again") { model.refresh() }
                    }
                }
            default:
                centered { ProgressView("Loading TASVideos catalog") }
            }
        } else {
            List(model.filtered) { publication in
                row(publication)
            }
            .listStyle(.inset)
        }
    }

    private func row(_ publication: TASPublication) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(publication.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle(for: publication))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(publication.publicationURL)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("View this publication on TASVideos")
            if let youtubeURL = publication.youtubeURL {
                Button {
                    NSWorkspace.shared.open(youtubeURL)
                } label: {
                    Image(systemName: "play.rectangle")
                }
                .buttonStyle(.borderless)
                .help("Watch on YouTube")
            }
            stateControl(for: publication)
        }
        .padding(.vertical, 2)
    }

    private func subtitle(for publication: TASPublication) -> String {
        [publication.authorsText,
         publication.durationText,
         publication.publicationClass ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    @ViewBuilder private func stateControl(for publication: TASPublication) -> some View {
        switch model.rowState(for: publication) {
        case .notInstalled:
            Button("Download") { model.download(publication) }
                .disabled(!model.moviesDirSet)
        case .downloading:
            ProgressView()
                .controlSize(.small)
        case .installed(hasROM: true):
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Downloaded; a matching ROM is in your ROM folder.")
        case .installed(hasROM: false):
            Label("No matching ROM", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help("Downloaded, but no ROM in your ROM folder has this movie's checksum.")
        case .failed(let message):
            Button("Retry") { model.download(publication) }
                .help(message)
        }
    }

    private var footer: some View {
        HStack {
            Text("New movies are picked up next time the wallpaper starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            (Text("Tool-assisted movies © their authors, from ")
             + Text("[TASVideos](https://tasvideos.org)")
             + Text(" under ")
             + Text("[CC BY 2.0](https://creativecommons.org/licenses/by/2.0/)"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func notice(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                content()
                Spacer()
            }
            Spacer()
        }
    }
}
