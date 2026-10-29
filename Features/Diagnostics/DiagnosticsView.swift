import SwiftUI
import UIKit

/// Вкладка самопроверки: прогоняет алгоритмы приложения на контрольных данных.
struct DiagnosticsView: View {
    @StateObject private var model = DiagnosticsModel()
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.checks.isEmpty {
                        Text("Нажмите «Проверить» — приложение прогонит свои алгоритмы на контрольных данных прямо на этом телефоне.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.checks) { check in
                            row(for: check)
                        }
                    }
                } header: {
                    sectionHeader
                }

                Section {
                    Button {
                        model.run()
                        copied = false
                    } label: {
                        Label(model.isRunning ? "Проверяю…" : "Проверить", systemImage: "play.circle")
                    }
                    .disabled(model.isRunning)

                    Button {
                        UIPasteboard.general.string = model.report
                        copied = true
                    } label: {
                        Label(copied ? "Отчёт скопирован" : "Скопировать отчёт", systemImage: "doc.on.doc")
                    }
                    .disabled(!model.hasRun)
                } footer: {
                    Text("Отчёт — обычный текст: если что-то не работает, вставьте его в чат.")
                }
            }
            .navigationTitle("Диагностика")
        }
    }

    @ViewBuilder
    private var sectionHeader: some View {
        if model.hasRun {
            Text(model.failedCount == 0 ? "Все проверки пройдены" : "Проблем: \(model.failedCount)")
        } else {
            Text("Самопроверка")
        }
    }

    private func row(for check: DiagnosticCheck) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: check))
                .foregroundStyle(color(for: check))
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(.subheadline.weight(.semibold))
                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func icon(for check: DiagnosticCheck) -> String {
        if check.passed { return "checkmark.circle.fill" }
        return check.critical ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
    }

    private func color(for check: DiagnosticCheck) -> Color {
        if check.passed { return .green }
        return check.critical ? .red : .orange
    }
}
