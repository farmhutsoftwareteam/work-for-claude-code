// Left rail (264px) — search input, scrollable project list with sizes,
// workbench tile grid at the bottom. Active project shows inset shadow + card bg.

import SwiftUI
import Inject

struct V2LeftRail: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @Binding var activeProject: V2Project

    var body: some View {
        VStack(spacing: 0) {
            search
            projectsHeader
            projectList
            workbenchRail
        }
        .background(v2.paper2)
        .overlay(alignment: .trailing) {
            Rectangle().fill(v2.line).frame(width: 1)
        }
        .enableInjection()
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(v2.faint)
            Text("Search projects & sessions")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(v2.faint)
            Spacer()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var projectsHeader: some View {
        HStack {
            Text("PROJECTS")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .kerning(1.2)
                .foregroundColor(v2.faint)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var projectList: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(V2Mock.projects) { project in
                    V2ProjectRow(project: project, isActive: project == activeProject) {
                        activeProject = project
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private var workbenchRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WORKBENCH")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .kerning(1.2)
                .foregroundColor(v2.faint)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)],
                spacing: 1
            ) {
                ForEach(V2Mock.workbenchTiles) { tile in
                    V2WorkbenchTileButton(tile: tile)
                }
            }
            .background(v2.line)
            .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
        }
        .padding(14)
        .background(v2.paper3)
        .overlay(alignment: .top) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }
}

// MARK: - Project row

private struct V2ProjectRow: View {
    @Environment(\.v2) private var v2
    let project: V2Project
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Circle()
                    .fill(project.live ? v2.ink : Color.clear)
                    .overlay(Circle().stroke(project.live ? Color.clear : v2.line2, lineWidth: 1))
                    .frame(width: 7, height: 7)
                Text(project.name)
                    .font(.system(size: 13.5, weight: isActive ? .medium : .regular))
                    .kerning(-0.13)
                    .foregroundColor(v2.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(project.size)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? v2.card : Color.clear)
            .overlay(alignment: .leading) {
                if isActive {
                    Rectangle().fill(v2.ink).frame(width: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Workbench tile

private struct V2WorkbenchTileButton: View {
    @Environment(\.v2) private var v2
    let tile: V2WorkbenchTile

    var body: some View {
        Button { } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(tile.label)
                        .font(.system(size: 12.5, weight: .medium))
                        .kerning(-0.13)
                        .foregroundColor(v2.ink)
                    Spacer()
                    Text(tile.count)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
                Text(tile.hint)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(v2.paper2)
        }
        .buttonStyle(.plain)
    }
}
