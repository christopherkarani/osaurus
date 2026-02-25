//
//  WorkOpenClawOnboardingView.swift
//  osaurus
//

import SwiftUI

struct WorkOpenClawOnboardingView: View {
    @ObservedObject private var openClawManager = OpenClawManager.shared
    @Environment(\.theme) private var theme

    @State private var hasAppeared = false
    @State private var didStartWizard = false
    @State private var sessionId: String?
    @State private var step: OpenClawWizardStep?
    @State private var status: OpenClawWizardRunStatus = .running
    @State private var isWorking = false
    @State private var errorMessage: String?

    @StateObject private var formState = OpenClawWizardStepFormState()

    private var isComplete: Bool {
        status == .done
    }

    private var primaryActionTitle: String {
        OpenClawWizardFlowLogic.primaryActionTitle(
            isComplete: isComplete,
            stepType: step?.type
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 20)
                    if didStartWizard {
                        wizardState
                    } else {
                        gateState
                    }
                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(theme.animationSlow()) { hasAppeared = true }
            }
            Task {
                await openClawManager.refreshOnboardingState(force: true)
            }
        }
        .onDisappear {
            hasAppeared = false
            Task { await cancelWizardIfNeeded() }
        }
    }

    private var gateTitle: String {
        if case .checking = openClawManager.onboardingState {
            return "Checking OpenClaw setup"
        }
        return "Finish OpenClaw Setup"
    }

    private var gateDescription: String {
        if case .checking = openClawManager.onboardingState {
            return "Verifying workspace onboarding status..."
        }
        return "Before Work mode can run tasks, OpenClaw needs one-time onboarding for your workspace."
    }

    private var shouldShowRetryConnection: Bool {
        !openClawManager.isConnected || openClawManager.onboardingFailureMessage != nil || errorMessage != nil
    }

    private var effectiveErrorMessage: String? {
        if let errorMessage, !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return errorMessage
        }
        return openClawManager.onboardingFailureMessage
    }

    private var gateState: some View {
        VStack(spacing: 28) {
            AnimatedOrb(color: theme.accentColor, size: .medium, seed: "work-onboarding")
                .frame(width: 88, height: 88)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.85)
                .animation(theme.springAnimation(), value: hasAppeared)

            VStack(spacing: 12) {
                Text(gateTitle)
                    .font(theme.font(size: CGFloat(theme.titleSize) + 4, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .multilineTextAlignment(.center)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 20)
                    .animation(theme.springAnimation().delay(0.1), value: hasAppeared)

                Text(gateDescription)
                    .font(theme.font(size: CGFloat(theme.bodySize) + 2))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 15)
                    .animation(theme.springAnimation().delay(0.17), value: hasAppeared)
            }

            if let effectiveErrorMessage {
                Text(effectiveErrorMessage)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.errorColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            VStack(spacing: 10) {
                Button {
                    Task { await startWizard() }
                } label: {
                    HStack(spacing: 8) {
                        if isWorking {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Image(systemName: "arrow.triangle.branch")
                        }
                        Text(isWorking ? "Starting..." : "Start OpenClaw Onboarding")
                    }
                    .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [theme.accentColor, theme.accentColor.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isWorking || openClawManager.onboardingState == .checking)

                if shouldShowRetryConnection {
                    Button {
                        Task { await retryConnectionAndRefresh() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry Connection")
                        }
                        .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(theme.secondaryBackground.opacity(0.8))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(theme.primaryBorder.opacity(0.7), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isWorking)
                }
            }
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared ? 1 : 0.95)
            .animation(theme.springAnimation().delay(0.25), value: hasAppeared)
        }
        .padding(.horizontal, 40)
    }

    private var wizardState: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text("OpenClaw Onboarding")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                statusPill
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()
                .overlay(theme.primaryBorder.opacity(0.55))

            VStack(alignment: .leading, spacing: 14) {
                if isComplete {
                    Label("OpenClaw setup complete", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.successColor)
                    Text("Preparing Work mode...")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                } else {
                    if let effectiveErrorMessage {
                        Text(effectiveErrorMessage)
                            .font(.system(size: 12))
                            .foregroundColor(theme.errorColor)
                    }

                    if let step {
                        if let title = step.title, !title.isEmpty {
                            Text(title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                        }

                        if let message = step.message, !message.isEmpty {
                            Text(message)
                                .font(.system(size: 12))
                                .foregroundColor(theme.secondaryText)
                        }

                        OpenClawWizardStepEditor(step: step, formState: formState)
                    } else {
                        ProgressView("Preparing onboarding flow...")
                            .progressViewStyle(CircularProgressViewStyle())
                            .tint(theme.accentColor)
                            .font(.system(size: 12))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()
                .overlay(theme.primaryBorder.opacity(0.55))

            HStack(spacing: 8) {
                HeaderSecondaryButton("Cancel setup", icon: "xmark") {
                    Task { await cancelAndReturnToGate() }
                }
                .disabled(isWorking)

                Spacer()

                HeaderPrimaryButton(primaryActionTitle, icon: isComplete ? "checkmark" : "arrow.right") {
                    if isComplete {
                        Task { await completeOnboarding() }
                    } else {
                        Task { await submitCurrentStep() }
                    }
                }
                .disabled(isWorking || (!isComplete && OpenClawWizardFlowLogic.isPrimaryActionBlocked(step: step)))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: 620)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.secondaryBackground.opacity(theme.isDark ? 0.82 : 0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.primaryBorder.opacity(0.35), lineWidth: 1)
                )
        )
        .padding(.horizontal, 24)
    }

    private var statusPill: some View {
        let label: String
        let color: Color

        switch status {
        case .running:
            label = isWorking ? "Applying" : "Running"
            color = theme.accentColor
        case .done:
            label = "Done"
            color = theme.successColor
        case .cancelled:
            label = "Cancelled"
            color = theme.warningColor
        case .error:
            label = "Error"
            color = theme.errorColor
        }

        return Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
    }

    private func retryConnectionAndRefresh() async {
        isWorking = true
        defer { isWorking = false }

        do {
            if !openClawManager.isConnected, openClawManager.gatewayStatus == .running {
                try await openClawManager.connect()
            }
            await openClawManager.refreshOnboardingState(force: true)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startWizard() async {
        isWorking = true
        defer { isWorking = false }

        do {
            if !openClawManager.isConnected {
                if openClawManager.gatewayStatus == .running {
                    try await openClawManager.connect()
                } else {
                    throw NSError(
                        domain: "WorkOpenClawOnboardingView",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "OpenClaw gateway is not connected."]
                    )
                }
            }

            let start = try await OpenClawGatewayConnection.shared.wizardStart(mode: "local", workspace: nil)
            sessionId = start.sessionId
            status = start.status ?? (start.done ? .done : .running)
            errorMessage = start.error
            didStartWizard = true
            apply(step: start.step)
            if start.done {
                await completeOnboarding()
            }
        } catch {
            didStartWizard = false
            status = .error
            errorMessage = error.localizedDescription
        }
    }

    private func submitCurrentStep() async {
        guard let step, let sessionId else { return }

        isWorking = true
        defer { isWorking = false }

        do {
            let value = formState.answerValue(for: step)
            let next = try await OpenClawGatewayConnection.shared.wizardNext(
                sessionId: sessionId,
                stepId: step.id,
                value: value
            )
            status = next.status ?? (next.done ? .done : .running)
            errorMessage = next.error
            apply(step: next.step)
            if next.done {
                await completeOnboarding()
            }
        } catch {
            status = .error
            errorMessage = error.localizedDescription
        }
    }

    private func completeOnboarding() async {
        await openClawManager.refreshStatus()
        await openClawManager.refreshOnboardingState(force: true)
        try? await openClawManager.fetchConfiguredProviders()
        errorMessage = nil
    }

    private func cancelAndReturnToGate() async {
        await cancelWizardIfNeeded()
        didStartWizard = false
        sessionId = nil
        step = nil
        status = .running
        errorMessage = nil
        await openClawManager.refreshOnboardingState(force: true)
    }

    private func cancelWizardIfNeeded() async {
        guard let sessionId else { return }
        guard !isComplete else { return }
        _ = try? await OpenClawGatewayConnection.shared.wizardCancel(sessionId: sessionId)
    }

    private func apply(step: OpenClawWizardStep?) {
        self.step = step
        guard let step else { return }
        formState.apply(step: step)
    }
}
