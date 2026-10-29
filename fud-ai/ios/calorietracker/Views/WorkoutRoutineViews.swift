import SwiftUI

/// Lists saved routines. Tapping one starts the selected day from it; rename
/// and delete live in each row's swipe actions and context menu.
struct WorkoutRoutinesSheet: View {
    @Environment(StrengthWorkoutStore.self) private var workoutStore
    let onApply: (StrengthWorkoutRoutine) -> Void
    let onClose: () -> Void

    @State private var renamingRoutine: StrengthWorkoutRoutine?
    @State private var renameText = ""
    @State private var pendingDeletion: StrengthWorkoutRoutine?

    private var isRenamePresented: Binding<Bool> {
        Binding(
            get: { renamingRoutine != nil },
            set: { if !$0 { renamingRoutine = nil } }
        )
    }

    private var isDeletePresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if workoutStore.routines.isEmpty {
                    ContentUnavailableView {
                        Label("No Routines Yet", systemImage: "list.bullet.rectangle.portrait")
                    } description: {
                        Text("Log a workout, then choose Save as routine from the + menu.")
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(workoutStore.sortedRoutines) { routine in
                            Button {
                                onApply(routine)
                            } label: {
                                WorkoutRoutineRow(routine: routine)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.workoutPanel.opacity(0.24))
                            .listRowSeparatorTint(Color.workoutHairline.opacity(0.28))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    pendingDeletion = routine
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                                .tint(Color(red: 0.58, green: 0.10, blue: 0.08))

                                Button {
                                    beginRename(routine)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(Color.workoutAccent)
                            }
                            .contextMenu {
                                Button {
                                    beginRename(routine)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    pendingDeletion = routine
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } footer: {
                        Text("Adds the routine's exercises to the selected day. Sets you already logged stay as they are.")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.workoutMutedText)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(Color.workoutBackground)
            .navigationTitle("Routines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose)
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Color.workoutAccent)
                }
            }
            .alert("Rename Routine", isPresented: isRenamePresented, presenting: renamingRoutine) { routine in
                TextField("Routine name", text: $renameText)
                Button("Cancel", role: .cancel) { renamingRoutine = nil }
                Button("Save") {
                    workoutStore.renameRoutine(routine.id, to: renameText)
                    renamingRoutine = nil
                }
                .disabled(StrengthWorkoutRoutinePlanner.sanitizedName(renameText).isEmpty)
            }
            .alert("Delete Routine?", isPresented: isDeletePresented, presenting: pendingDeletion) { routine in
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
                Button("Delete", role: .destructive) {
                    workoutStore.deleteRoutine(routine.id)
                    pendingDeletion = nil
                }
            } message: { _ in
                Text("Workouts you already logged are kept.")
            }
        }
    }

    private func beginRename(_ routine: StrengthWorkoutRoutine) {
        renameText = routine.name
        renamingRoutine = routine
    }
}

private struct WorkoutRoutineRow: View {
    let routine: StrengthWorkoutRoutine

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.headline.weight(.black))
                .foregroundStyle(Color.workoutAccent)
                .frame(width: 38, height: 38)
                .background(Color.workoutCard.opacity(0.60), in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.workoutHairline.opacity(0.34), lineWidth: 0.7)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(routine.name)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.workoutCharcoal)
                    .lineLimit(1)
                Text(routine.exerciseSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.workoutMutedText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "plus")
                .font(.caption.weight(.black))
                .foregroundStyle(Color.workoutOnAccent)
                .frame(width: 28, height: 28)
                .background(Color.workoutAccent, in: Circle())
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
