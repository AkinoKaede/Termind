import Foundation
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileNavigationParityTests {
    @Test func assistantUsesTopTitleSwitchingAndNativeConversationListsWithoutAnIPadSidebar() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assistant = try String(
            contentsOf: root.appending(path: "TFI/Features/Assistant/MobileAssistantView.swift"), encoding: .utf8)
        let transcript = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileAssistantConversation.swift"), encoding: .utf8)
        let workRows = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileAssistantWorkRow.swift"), encoding: .utf8)
        let workspaceList = try String(
            contentsOf: root.appending(path: "TFI/Features/Workspaces/MobileWorkspaceListView.swift"),
            encoding: .utf8)
        let currentConversationMenu = try #require(
            assistant.components(separatedBy: ".toolbar {").dropFirst().first?
                .components(separatedBy: ".navigationDestination").first)
        let titleMenu = try #require(
            assistant.components(separatedBy: "@ViewBuilder private var conversationTitleMenu").last?
                .components(separatedBy: "private func titleMenuButton").first)
        let bottomSurface = try #require(
            transcript.components(separatedBy: "@ViewBuilder private var bottomSurface").last?
                .components(separatedBy: "private var archivedNotice").first)
        let assistantRows = try #require(
            assistant.components(separatedBy: "private func conversationRow").last?
                .components(separatedBy: "private func select").first)
        let conversationActions = try #require(
            assistant.components(separatedBy: "@ViewBuilder private func actions").last?
                .components(separatedBy: "private func canChangeHistory").first)
        let workspaceRows = try #require(
            workspaceList.components(separatedBy: "private var workspaceRows").last?
                .components(separatedBy: "private func statusTint").first)

        #expect(assistant.contains(".toolbarTitleMenu"))
        #expect(assistant.contains("@Binding var libraryRoute: MobileAssistantLibraryRoute?"))
        #expect(assistant.contains(".navigationDestination(item: $libraryRoute)"))
        #expect(assistant.contains("List {"))
        #expect(!assistant.contains("MobileNativeList("))
        #expect(!assistant.contains(".listStyle(.plain)"))
        #expect(!assistant.contains(".scrollContentBackground(.hidden)"))
        #expect(!assistant.contains(".background(Color(uiColor: .systemBackground))"))
        #expect(!assistant.contains("minHeight: 48"))
        #expect(!assistantRows.contains("minHeight: 60"))
        #expect(!assistantRows.contains(".font(.headline)"))
        #expect(!assistantRows.contains(".lineLimit(2)"))
        #expect(assistantRows.contains("Text(conversation.derivedTitle).foregroundStyle(.primary).lineLimit(1)"))
        for layout in [
            "HStack(spacing: 12)",
            ".frame(width: 28, height: 28)",
            "VStack(alignment: .leading, spacing: 2)",
            "Spacer(minLength: 0)",
            ".frame(maxWidth: .infinity, alignment: .leading)",
        ] {
            #expect(assistantRows.contains(layout))
            #expect(workspaceRows.contains(layout))
        }
        #expect(!assistant.contains("geometry.size.width >= 760"))
        #expect(!assistant.contains("MobileAssistantLibrary(model: model, selected: {})"))
        #expect(assistant.contains(".swipeActions(edge: .trailing, allowsFullSwipe: true)"))
        #expect(assistant.contains("Button(\"Archive\", systemImage: \"archivebox\", role: .destructive)"))
        #expect(assistant.contains("Button(\"Unarchive\", systemImage: \"arrow.uturn.backward\")"))
        #expect(currentConversationMenu.contains("if model.conversation.isArchived"))
        #expect(currentConversationMenu.contains("Button(\"Delete\", systemImage: \"trash\", role: .destructive)"))
        #expect(conversationActions.contains("if conversation.isArchived"))
        #expect(conversationActions.contains("Button(\"Delete\", systemImage: \"trash\", role: .destructive)"))
        #expect(assistantRows.contains("Button(\"Archive\", systemImage: \"archivebox\", role: .destructive)"))
        #expect(!assistantRows.contains(".tint(.orange)"))
        #expect(!assistant.contains("MobileCardIcon(symbol: conversation.isArchived"))
        #expect(assistant.contains(".foregroundStyle(.secondary)"))
        let conversations = try #require(currentConversationMenu.range(of: "Button(\"Conversations\""))
        let archived = try #require(currentConversationMenu.range(of: "Button(\"Archived\""))
        let divider = try #require(currentConversationMenu.range(of: "Divider()"))
        #expect(conversations.lowerBound < archived.lowerBound)
        #expect(archived.lowerBound < divider.lowerBound)
        #expect(!titleMenu.contains("\"New Conversation\""))
        #expect(!titleMenu.contains("Button(\"Conversations\""))
        #expect(!titleMenu.contains("Button(\"Archived\""))
        #expect(transcript.contains("MobileNativeList("))
        #expect(transcript.contains("surface: .plain"))
        #expect(transcript.contains("AssistantTranscriptEntry.items("))
        #expect(transcript.contains("messageAction(\"Edit\""))
        #expect(transcript.contains("messageAction(\"Copy\""))
        #expect(transcript.contains("messageAction(\"Fork\""))
        #expect(!transcript.contains("Text(\"Assistant\")"))
        #expect(transcript.contains("AssistantTranscriptPresentationState()"))
        #expect(transcript.contains("DisclosureGroup(isExpanded: disclosureBinding"))
        #expect(!transcript.contains("LazyVStack"))
        #expect(workRows.contains("if batch.cards.count == 1, let card = batch.cards.first"))
        #expect(workRows.contains("defaultExpanded: true"))
        #expect(workRows.contains("presentation.isExpanded(.toolBatch(batch.id))"))
        #expect(workRows.contains("presentation.isExpanded(.tool(card.id), default: defaultExpanded)"))
        #expect(bottomSurface.contains(".background(Color(uiColor: .systemBackground))"))
        #expect(!bottomSurface.contains(".background(.bar)"))
    }

    @Test func assistantBlockingInteractionsReplaceTheComposerAndSingleOptionsAdvance() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let conversation = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileAssistantConversation.swift"), encoding: .utf8)
        let interaction = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileAssistantInteraction.swift"), encoding: .utf8)
        let bottomSurface = try #require(
            conversation.components(separatedBy: "@ViewBuilder private var bottomSurface").last?
                .components(separatedBy: "private var archivedNotice").first)
        let blockingSurface = try #require(
            bottomSurface.components(separatedBy: "conversation.pendingUserInteraction != nil {").last?
                .components(separatedBy: "} else {").first)
        let composerSurface = try #require(bottomSurface.components(separatedBy: "} else {").last)
        let regularSurface = try #require(
            conversation.components(separatedBy: "private var regularInteractionSurface").last?
                .components(separatedBy: "private var archivedNotice").first
        )
        let regularFlow = try #require(
            regularSurface.components(separatedBy: "VStack(spacing: 8) {").last?
                .components(separatedBy: ".zIndex(20)").first
        )

        #expect(
            bottomSurface.contains(
                "conversation.pendingApproval != nil || conversation.pendingUserInteraction != nil"))
        #expect(blockingSurface.contains("MobileAssistantInteraction("))
        #expect(!blockingSurface.contains("MobileAssistantComposer("))
        #expect(!blockingSurface.contains("MobileAssistantTaskCapsule("))
        #expect(!blockingSurface.contains("MobileAssistantSteeringQueue("))
        #expect(blockingSurface.contains(".background(Color(uiColor: .systemBackground))"))
        #expect(composerSurface.contains("regularInteractionSurface"))
        #expect(regularSurface.contains("ZStack(alignment: .top)"))
        #expect(regularFlow.contains("MobileAssistantSteeringQueue("))
        #expect(regularFlow.contains("MobileAssistantComposer("))
        #expect(!regularFlow.contains("MobileAssistantTaskCapsule("))
        #expect(regularSurface.contains("MobileAssistantTaskCapsule("))
        #expect(regularSurface.contains(".offset(y: -44)"))
        #expect(!composerSurface.contains("MobileAssistantInteraction("))
        #expect(composerSurface.contains(".background(Color(uiColor: .systemBackground))"))
        #expect(interaction.contains("conversation.answerUserInputOption(option.id, in: questionID)"))
        #expect(!interaction.contains("conversation.toggleUserInputOption(option.id, in: questionID)"))
        #expect(interaction.components(separatedBy: "MobileAssistantAdaptiveHeight {").count == 3)
        #expect(interaction.contains("ViewThatFits(in: .vertical)"))
        #expect(interaction.contains(".scrollBounceBehavior(.basedOnSize)"))
        #expect(interaction.contains(".frame(maxWidth: .infinity, maxHeight: 300, alignment: .topLeading)"))
        #expect(!interaction.contains(".frame(maxHeight: 160)"))

        let secretField = try #require(
            interaction.components(separatedBy: "private func secretField").last?
                .components(separatedBy: "private func textField").first
        )
        #expect(secretField.contains(".submitLabel(isLastQuestion ? .done : .next)"))
        #expect(secretField.contains(".onSubmit { advanceFromKeyboard(question.id) }"))

        let customRow = try #require(
            interaction.components(separatedBy: "private func customRow").last?
                .components(separatedBy: "private func customAnswerField").first
        )
        #expect(customRow.contains("HStack(alignment: .center"))
        #expect(customRow.contains(".submitLabel(isLastQuestion ? .done : .next)"))
        #expect(customRow.contains(".onSubmit { advanceFromKeyboard(questionID) }"))

        let customField = try #require(
            interaction.components(separatedBy: "private func customAnswerField").last?
                .components(separatedBy: "private func footer").first
        )
        #expect(!customField.contains("axis: .vertical"))
    }

    @Test func assistantSteeringTasksAndPlanActionsMatchDesktopHierarchy() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let conversation = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileAssistantConversation.swift"),
            encoding: .utf8
        )
        let composer = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileAssistantComposer.swift"), encoding: .utf8)
        let cards = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileAssistantTranscriptCards.swift"),
            encoding: .utf8
        )

        #expect(!composer.contains("pendingSteering"))
        #expect(conversation.contains("struct MobileAssistantSteeringQueue"))
        #expect(conversation.contains("Label(\"Steering\", systemImage: \"arrow.turn.down.right\")"))
        #expect(conversation.contains("conversation.returnSteeringToDraft(pending.id)"))
        #expect(conversation.contains(".frame(height: min(rowsHeight, 88))"))
        let steeringQueue = try #require(
            conversation.components(separatedBy: "private struct MobileAssistantSteeringQueue").last?
                .components(separatedBy: "struct MobileAssistantConversation").first
        )
        #expect(steeringQueue.contains("Image(systemName: \"xmark\")"))
        #expect(!steeringQueue.contains(".onHover"))
        #expect(conversation.contains("struct MobileAssistantTaskCapsule"))
        #expect(conversation.contains("ProgressRing("))
        #expect(conversation.contains(".offset(y: -overlayHeight)"))
        #expect(conversation.contains(".frame(height: min(rowsHeight, 160))"))
        #expect(conversation.contains("case .inProgress: \"circle.lefthalf.filled\""))
        #expect(conversation.contains("Color(uiColor: .secondaryLabel)"))
        #expect(conversation.contains(".strikethrough("))

        let wideLayout = try #require(
            cards.components(separatedBy: "ViewThatFits(in: .horizontal) {").last?
                .components(separatedBy: "VStack(alignment: .leading, spacing: 8)").first
        )
        let discard = try #require(wideLayout.range(of: "discardButton")?.lowerBound)
        let hint = try #require(wideLayout.range(of: "planningHint")?.lowerBound)
        let implement = try #require(wideLayout.range(of: "implementButton")?.lowerBound)
        #expect(discard < hint)
        #expect(hint < implement)
    }

    @Test func assistantHoistsComposerFocusAndRestoresItOnlyAcrossRequestedNavigation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assistant = try String(
            contentsOf: root.appending(path: "TFI/Features/Assistant/MobileAssistantView.swift"), encoding: .utf8)
        let conversation = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileAssistantConversation.swift"), encoding: .utf8)
        let composer = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileAssistantComposer.swift"), encoding: .utf8)

        #expect(assistant.contains("@FocusState private var composerFocused: Bool"))
        #expect(assistant.contains("restoreComposerFocusAfterLibrary = composerFocused"))
        #expect(assistant.contains("replaceConversation(preservingComposerFocus: model.newConversation)"))
        #expect(assistant.contains("replaceConversation { model.select(conversation) }"))
        #expect(assistant.contains("guard requested, canFocusComposer else { return }"))
        #expect(assistant.contains("await Task.yield()"))
        #expect(assistant.contains("composerFocusRequest = nextComposerFocusRequest"))
        #expect(assistant.contains("composerFocusRequestHandled: composerFocusRequestHandled"))
        #expect(conversation.contains("onTap: { composerFocus.wrappedValue = false }"))
        #expect(conversation.contains("focus: composerFocus"))
        #expect(composer.contains(".focused(activeFocus)"))
        #expect(composer.contains(".task(id: focusRequest)"))
        #expect(composer.contains("await Task.yield()"))
        #expect(composer.contains("guard !Task.isCancelled else { return }"))
        #expect(composer.contains("activeFocus.wrappedValue = true"))
        #expect(composer.contains("focusRequestHandled(focusRequest)"))
    }

    @Test func speechAudioTapDoesNotInheritMainActorIsolation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "TFI/Platform/IOSSpeechAudioInput.swift"), encoding: .utf8)

        #expect(source.contains("nonisolated static func makeTapHandler"))
        #expect(source.contains("block: Self.makeTapHandler"))
    }

    @Test func speechComposerUsesTheSharedLevelDrivenWaveformAndMobileTouchTargets() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileAssistantComposer.swift"), encoding: .utf8)

        #expect(source.contains("SpeechWaveformView("))
        #expect(source.contains("samples: model.speech.levelSamples"))
        #expect(source.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        #expect(source.contains(".transition(.opacity)"))
        #expect(source.contains(".smooth(duration: 0.22)"))
        #expect(source.contains("minHeight: 48, maxHeight: 48"))
        #expect(!source.contains(".symbolEffect(.variableColor)"))
    }

    @Test func nativeListOmitsSwipeDeletionAndSFTPRowsKeepAlignedMetadataWithoutSeparators() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let nativeList = try String(
            contentsOf: root.appending(path: "TFI/UI/Components/MobileNativeList.swift"), encoding: .utf8)
        let assistant = try String(
            contentsOf: root.appending(path: "TFI/Features/Assistant/MobileAssistantView.swift"), encoding: .utf8)
        let sftp = try String(
            contentsOf: root.appending(path: "TFI/Features/SFTP/MobileSFTPBrowser.swift"), encoding: .utf8)

        #expect(!nativeList.contains("onDelete"))
        #expect(!nativeList.contains("canDelete"))
        #expect(!nativeList.contains("UIPanGestureRecognizer"))
        #expect(!nativeList.contains("deleteButton"))
        #expect(!assistant.contains("onDelete:"))
        #expect(assistant.contains("Button(\"Delete\", systemImage: \"trash\", role: .destructive)"))
        #expect(!sftp.contains("onDelete:"))
        #expect(sftp.contains("Button(\"Delete\", systemImage: \"trash\", role: .destructive)"))
        #expect(sftp.contains("MobileSFTPPathBar(session: session, connected: connected)\n            Divider()"))
        #expect(!sftp.contains(".overlay(alignment: .bottom) { Divider()"))
        #expect(sftp.contains("Text(verbatim: \"..\")"))
        #expect(!sftp.contains("Text(\"..\")"))
        #expect(sftp.contains("Text(verbatim: \"0\")"))
        #expect(sftp.contains(".hidden()"))
        #expect(sftp.contains(".accessibilityHidden(true)"))
    }

    @Test func assistantSlashRowsUseThreeCompactTouchSizedLinesWithEvenVerticalPadding() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let slash = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileSlashCommandPanel.swift"), encoding: .utf8)

        #expect(slash.contains("rowHeight = 64.0"))
        #expect(!slash.contains("headerHeight"))
        #expect(!slash.contains("private var header"))
        #expect(!slash.contains("onBack"))
        #expect(!slash.contains("onClose"))
        #expect(slash.contains("min(completion.rows.count, 3)"))
        #expect(slash.contains("HStack(alignment: .center, spacing: 12)"))
        #expect(!slash.contains("HStack(alignment: .top, spacing: 12)"))
        #expect(slash.contains(".padding(.vertical, 8)"))
        #expect(!slash.contains("minHeight: 54"))
        #expect(!slash.contains("maxHeight: 54"))
        #expect(slash.contains("Text(verbatim: command.summary)"))
        #expect(slash.contains("Text(verbatim: option.detail.isEmpty ? \" \" : option.detail)"))
        #expect(slash.contains(".lineLimit(1).truncationMode(.tail)"))
    }

    @Test func assistantCompactionMatchesDesktopAndComposerShowsNoInlineErrors() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let composer = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileAssistantComposer.swift"), encoding: .utf8)
        let conversation = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileAssistantConversation.swift"), encoding: .utf8)

        #expect(composer.contains("\"Attachment Error\""))
        #expect(composer.contains("get: { composer.attachmentImportError != nil }"))
        #expect(!composer.contains("if let error = composer.attachmentImportError"))
        #expect(!composer.contains("conversation.isCompacting { ProgressView"))
        #expect(!composer.contains("conversation.compactionActivity?.state"))

        #expect(conversation.contains("case .compactionActivity(let activity): compactionActivityRow(activity)"))
        #expect(conversation.contains("Text(\"Compacting context\")"))
        #expect(conversation.contains("Text(\"Couldn’t compact context\")"))
        #expect(
            conversation.contains(
                "DisclosureGroup(isExpanded: disclosureBinding(for: .compactionActivity(activity.id)))"))
        #expect(conversation.contains(".tint(.secondary)"))
        #expect(conversation.contains("Text(reason)"))
        #expect(conversation.contains(".font(.caption.monospaced())"))
        #expect(conversation.contains("ContextBreakdownView.compact(mark.summarizedTokens)"))
        #expect(conversation.contains("ContextBreakdownView.compact(mark.keptTokens)"))
        #expect(conversation.contains("systemImage: \"doc.text\""))
        #expect(conversation.contains("Earlier turns are summarized for the model. Nothing was deleted."))
    }

    @Test func assistantSeparatesEffectiveModelFromEffortWithoutAnAutomaticChoice() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let composer = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileAssistantComposer.swift"), encoding: .utf8)

        #expect(composer.contains("Section(\"Context\")"))
        #expect(composer.contains("showsTitle: false"))
        #expect(composer.contains("Section(\"Model\") {\n                    assistantModelPicker"))
        #expect(composer.contains("Picker(\"Effort\""))
        #expect(!composer.contains(".pickerStyle(.inline)"))
        #expect(composer.contains(".navigationTitle(\"Model\")"))
        #expect(composer.contains("Button(\"Done\", systemImage: \"checkmark\")"))
        #expect(composer.contains("get: { resolvedModelRef }"))
        #expect(!composer.contains("Text(\"Automatic\")"))
        #expect(!composer.contains("private var controls:"))
        #expect(composer.contains("slashRegistry.commands(in: slashContext)"))
        #expect(composer.contains(".onSubmit(submitFromKeyboard)"))
        #expect(composer.contains(".onKeyPress(.escape"))
        let badges = try #require(
            composer.components(separatedBy: "private var badges").last?
                .components(separatedBy: "private var modelProviders").first)
        #expect(badges.contains("armedSkillName"))
        #expect(badges.components(separatedBy: "MobileDismissibleComposerBadge(").count == 3)
        #expect(composer.contains(".symbolRenderingMode(.monochrome)"))
    }

    @Test func assistantPlanAndSkillBadgesExposeDesktopHoverRemovalAffordance() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let composer = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileAssistantComposer.swift"), encoding: .utf8)

        let badge = try #require(
            composer.components(separatedBy: "private struct MobileDismissibleComposerBadge").last?
                .components(separatedBy: "struct MobileAssistantComposer").first)
        #expect(badge.contains("@State private var isHovering = false"))
        #expect(badge.contains("isHovering ? \"xmark\" : symbol"))
        #expect(badge.contains(".contentTransition(.symbolEffect(.replace))"))
        #expect(badge.contains(".mobileComposerControlIcon(opacity: 0.62)"))
        #expect(badge.contains(".onHover { isHovering = $0 }"))
        #expect(badge.contains(".help(help)"))
        #expect(badge.contains(".accessibilityLabel(accessibilityLabel)"))

        let badges = try #require(
            composer.components(separatedBy: "@ViewBuilder private var badges").last?
                .components(separatedBy: "private var modelProviders").first)
        #expect(badges.contains("symbol: \"lightbulb.max\""))
        #expect(badges.contains("conversation.isPlanning = false"))
        #expect(badges.contains("Text(\"Plan mode — click to turn off\")"))
        #expect(badges.contains("Text(\"Plan mode on, turn off\")"))
        #expect(badges.contains("symbol: \"book.closed\""))
        #expect(badges.contains("composer.armedSkillName = nil"))
        #expect(badges.contains("Skill \\(skill) armed, remove"))
    }

    @Test func assistantPermissionMenuUsesLeadingCheckmarkAndKeepsItsTriggerVisible() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let composer = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileAssistantComposer.swift"), encoding: .utf8)
        let permissionMenu = try #require(
            composer.components(separatedBy: "private var permissionMenu").last?
                .components(separatedBy: "private var resolvedPermissionMode").first)

        #expect(!permissionMenu.contains("Picker("))
        #expect(permissionMenu.contains("Button(role: mode == .fullAccess ? .destructive : nil)"))
        #expect(permissionMenu.contains(".menuOrder(.fixed)"))
        #expect(permissionMenu.contains("mode == resolvedPermissionMode ? \"checkmark\" : mode.symbol"))
        #expect(permissionMenu.contains("Label(\"Permissions\", systemImage: resolvedPermissionMode.symbol)"))
        #expect(
            permissionMenu.contains(
                ".mobileComposerControlIcon(isDestructive: resolvedPermissionMode == .fullAccess)"))
        #expect(!permissionMenu.contains("AnyShapeStyle"))
        #expect(permissionMenu.contains(".labelStyle(.iconOnly)"))
        #expect(permissionMenu.contains(".fixedSize()"))
        #expect(permissionMenu.contains(".layoutPriority(1)"))
        #expect(permissionMenu.contains("conversation.permissionMode = mode"))
        #expect(permissionMenu.contains("model.configuration.select(mode)"))
    }

    @Test func assistantPermissionSelectionUsesDeviceLocalDefaults() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appModel = try String(
            contentsOf: root.appending(path: "TFI/App/MobileAppModel.swift"), encoding: .utf8)

        #expect(appModel.contains("permissionDefaults: settingsDefaults"))
    }

    @Test func assistantAddMenuContainsOnlyOrderedAttachmentSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let composer = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileAssistantComposer.swift"), encoding: .utf8)
        let addMenu = try #require(
            composer.components(separatedBy: "private var addMenu").last?
                .components(separatedBy: "private var permissionMenu").first)

        let camera = try #require(addMenu.range(of: "Button(\"Camera\""))
        let photos = try #require(addMenu.range(of: "Button(\"Photos\""))
        let files = try #require(addMenu.range(of: "Button(\"Files\""))
        #expect(camera.lowerBound < photos.lowerBound)
        #expect(photos.lowerBound < files.lowerBound)
        #expect(!addMenu.contains("Voice Input"))
        #expect(!addMenu.contains("Divider()"))
    }

    @Test func assistantNeutralControlsShareVisualStyleAndAlignWithSend() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let composer = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileAssistantComposer.swift"), encoding: .utf8)

        let style = try #require(
            composer.components(separatedBy: "private struct MobileComposerControlIconModifier").last?
                .components(separatedBy: "extension View").first)
        #expect(style.contains("isDestructive ? .red : Color.primary.opacity(opacity)"))
        #expect(style.contains(".font(.title3.weight(.medium))"))
        #expect(style.contains(".symbolRenderingMode(.monochrome)"))
        #expect(style.contains(".foregroundStyle(tint)"))
        #expect(style.contains(".frame(width: 48, height: 48, alignment: .center)"))
        #expect(style.contains(".contentShape(.circle)"))

        let styleEntryPoint = try #require(composer.components(separatedBy: "extension View").last)
        #expect(styleEntryPoint.contains("opacity: Double = 0.75"))

        let standardControls = try #require(
            composer.components(separatedBy: "private var standardControls").last?
                .components(separatedBy: "private var recordingControls").first)
        #expect(standardControls.contains("HStack(alignment: .center, spacing: 2)"))

        for markers in [
            ("private var recordingControls", "private var addMenu"),
            ("private var addMenu", "private var permissionMenu"),
            ("private var permissionMenu", "private var resolvedPermissionMode"),
            ("private var microphoneButton", "@ViewBuilder private var primaryButton"),
        ] {
            let controls = try #require(
                composer.components(separatedBy: markers.0).last?
                    .components(separatedBy: markers.1).first)
            #expect(controls.contains(".mobileComposerControlIcon"))
        }

        let badges = try #require(
            composer.components(separatedBy: "@ViewBuilder private var badges").last?
                .components(separatedBy: "private var modelProviders").first)
        #expect(badges.components(separatedBy: "MobileDismissibleComposerBadge(").count == 3)

        let dismissibleBadge = try #require(
            composer.components(separatedBy: "private struct MobileDismissibleComposerBadge").last?
                .components(separatedBy: "struct MobileAssistantComposer").first)
        #expect(dismissibleBadge.contains(".mobileComposerControlIcon(opacity: 0.62)"))

        let primaryButton = try #require(
            composer.components(separatedBy: "@ViewBuilder private var primaryButton").last?
                .components(separatedBy: "private var contextDetailsSheet").first)
        #expect(primaryButton.contains(".font(.system(size: 34, weight: .semibold))"))
        #expect(primaryButton.contains(".frame(width: 48, height: 48)"))
    }

    @Test func vaultReplacesWelcomeAndMetricsRemainsBelowItOnIPad() {
        let features = MobileFeatureRegistry.standard()
        #expect(features.registrations(on: .phoneTab).map(\.id) == [.vault, .workspaces, .assistant, .settings])
        #expect(
            features.registrations(on: .padSidebar).map(\.id)
                == [.vault, .metrics, .workspaces, .assistant, .settings]
        )
    }

    @Test func aiSettingsUseThreeNativeManagementPages() {
        #expect(MobileAISettingsDestination.allCases == [.models, .skills, .mcp])
    }

    @Test func iPadSidebarOmitsBrandTitle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rootSource = try String(
            contentsOf: root.appending(path: "TFI/App/MobileRootView.swift"), encoding: .utf8)
        #expect(!rootSource.contains(".navigationTitle(\"Termind\")"))
    }

    @Test func vaultOnlyShowsMetricsWhenTheSidebarDoesNotProvideIt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let registrySource = try String(
            contentsOf: root.appending(path: "TFI/App/MobileFeatureRegistry.swift"), encoding: .utf8)
        let vaultSource = try String(
            contentsOf: root.appending(path: "TFI/Features/Vault/MobileVaultView.swift"), encoding: .utf8)

        #expect(registrySource.contains("showsMetrics: surface == .phoneTab"))
        #expect(vaultSource.contains("guard showsMetrics else { return [] }"))
        #expect(vaultSource.contains("if showsMetrics {"))
    }

    @Test func aiSettingsRowsUseDirectDestinationsInsideTheParentStack() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "TFI/Features/Settings/MobileAISettingsView.swift"), encoding: .utf8)
        let index = try #require(source.components(separatedBy: "enum MobileAISettingsDestination").first)
        #expect(index.contains("NavigationLink {"))
        #expect(!index.contains("NavigationLink(value:"))
        #expect(!index.contains("navigationDestination"))
    }

    @Test func mcpUsesNativeListNavigationAndDraftHeaderRows() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "TFI/Features/Settings/MobileMCPSettings.swift"), encoding: .utf8)
        let list = try #require(source.components(separatedBy: "private struct MobileMCPServerRow").first)
        let editor = try #require(source.components(separatedBy: "struct MobileMCPEditor").last)

        #expect(list.contains("NavigationLink {"))
        #expect(list.contains(".navigationDestination(item: $adding)"))
        #expect(!list.contains(".sheet(item:"))
        #expect(editor.contains("ForEach(model.draft.headers)"))
        #expect(editor.contains(".onDelete(perform: model.removeHeaders)"))
        #expect(editor.contains("MobileMCPHeaderEditor"))
    }

    @Test func metricsUsesAvailableWidthRatherThanDeviceOrientation() {
        #expect(!MobileMetricsDetailPage.showsBothColumns(width: 430))
        #expect(!MobileMetricsDetailPage.showsBothColumns(width: 680))
        #expect(MobileMetricsDetailPage.showsBothColumns(width: 700))
        #expect(MobileMetricsDetailPage.showsBothColumns(width: 1024))
    }

    @Test func metricsProcessListRemovesItsTopMarginAndKeepsLongPIDsReadable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "TFI/Features/Metrics/MobileMetricsView.swift"), encoding: .utf8)
        let processes = try #require(source.components(separatedBy: "struct MobileMetricsProcessesView").last)

        #expect(processes.contains(".contentMargins(.top, 0, for: .scrollContent)"))
        #expect(processes.contains(".font(.caption.monospacedDigit())"))
        #expect(processes.contains(".fixedSize(horizontal: true, vertical: false)"))
        #expect(processes.contains(".frame(minWidth: 64, alignment: .leading)"))
    }

    @Test func connectionFailuresStayInJourneyAndCancellationLeavesTheDetail() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspace = try String(
            contentsOf: root.appending(path: "TFI/Features/Workspaces/MobileWorkspaceView.swift"), encoding: .utf8)
        #expect(!workspace.contains("\"Connection Error\""))
        #expect(workspace.contains("get: { presentedOperationError != nil }"))
        #expect(workspace.contains("workspace.sftpSession.operationError = nil"))
        #expect(workspace.contains("cancel: { closeWorkspace(workspace.id) }"))

        let metrics = try String(
            contentsOf: root.appending(path: "TFI/Features/Metrics/MobileMetricsView.swift"), encoding: .utf8)
        #expect(metrics.contains("app.metrics.core.setEnabled(false, for: server)"))
        #expect(metrics.contains("dismiss()"))

        let appModel = try String(
            contentsOf: root.appending(path: "TFI/App/MobileAppModel.swift"), encoding: .utf8)
        #expect(!appModel.contains("mobile.workspaces.v1"))
        #expect(appModel.contains("workspace.resumeAfterBackground()"))
    }

    @Test func workspaceListOffersLongPressCloseAndKeepsCloseAllInsideMore() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspaceList = try String(
            contentsOf: root.appending(path: "TFI/Features/Workspaces/MobileWorkspaceListView.swift"),
            encoding: .utf8)
        #expect(workspaceList.contains(".contextMenu {"))
        #expect(workspaceList.contains("Button(\"Close\", systemImage: \"xmark\", role: .destructive)"))
        #expect(workspaceList.contains("scene.closeWorkspace(workspace.id)"))

        let toolbar = try String(
            contentsOf: root.appending(path: "TFI/Features/HostChooser/MobileConnectionPicker.swift"), encoding: .utf8)
        #expect(toolbar.contains("Menu {"))
        #expect(toolbar.contains("Button(\"Close All Workspaces\""))
        #expect(toolbar.contains("systemImage: \"rectangle.stack.badge.minus\", role: .destructive"))
        #expect(toolbar.contains(".disabled(!hasWorkspaces)"))
        #expect(toolbar.contains("MobileOverflowMenuLabel(\"More\")"))
    }

    @Test func workspaceSupportsCommandGenerationAndBatchUploadEntryPoints() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspace = try String(
            contentsOf: root.appending(path: "TFI/Features/Workspaces/MobileWorkspaceView.swift"),
            encoding: .utf8
        )
        let workspaceView = try #require(
            workspace.components(separatedBy: "struct MobileWorkspaceView: View").last
        )
        let rootSurface = try #require(
            workspaceView.components(separatedBy: "var body: some View").dropFirst().first?
                .components(separatedBy: "private var workspaceChrome").first
        )

        #expect(workspace.contains("Button(\"Generate Command\", systemImage: \"sparkles\")"))
        #expect(!workspace.contains(".keyboardShortcut("))
        #expect(rootSurface.contains("MobileWindowDropTarget("))
        #expect(rootSurface.contains("terminalView: workspace.uploadTerminalView"))
        #expect(!rootSurface.contains(".frame(width: 0, height: 0)"))
        #expect(rootSurface.contains("receive: receiveUploadProviders"))
        #expect(rootSurface.contains("DropTargetOverlay(presentation: uploadDropPresentation)"))
        #expect(workspace.contains("allowedContentTypes: [.data, .folder]"))
        #expect(workspace.contains("allowsMultipleSelection: true"))
    }

    @Test func assistantConversationAcceptsFilesAndImagesAcrossItsWholeSurface() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let conversation = try String(
            contentsOf: root.appending(path: "TFI/Features/AI/MobileAssistantConversation.swift"),
            encoding: .utf8
        )

        #expect(conversation.contains(".mobileConversationAttachmentDropTarget("))
        #expect(conversation.contains("of: [.fileURL, .image]"))
        #expect(conversation.contains("MobileDropPayloadLoader.load"))
        #expect(conversation.contains("DropTargetOverlay("))
        #expect(conversation.contains("!conversation.isArchived"))
        #expect(conversation.contains("conversation.pendingApproval == nil"))
        #expect(conversation.contains("conversation.pendingUserInteraction == nil"))
    }

    @Test func knownHostsExposeAlignedCardActionsAndEditing() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "TFI/Features/KnownHosts/MobileKnownHostsView.swift"), encoding: .utf8)

        #expect(source.contains("MobileActionCard"))
        #expect(source.contains("symbol: \"touchid\""))
        #expect(source.contains("Button(\"Edit\", systemImage: \"pencil\")"))
        #expect(source.contains("Button(\"Copy Fingerprint\", systemImage: \"doc.on.doc\")"))
        #expect(source.contains("Button(\"Delete\", systemImage: \"trash\", role: .destructive)"))
        #expect(source.contains("MobileKnownHostEditor(app: app, entry: $0)"))
        #expect(source.contains(".relative(presentation: .numeric).locale(locale)"))
        #expect(!source.contains("Fingerprint Mismatch"))
        #expect(!source.contains("title: \"Host key changed\""))
    }

    @Test func mobileListsCardsAndPaywallKeepTheRefinedPresentation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let metrics = try String(
            contentsOf: root.appending(path: "TFI/Features/Metrics/MobileMetricsView.swift"), encoding: .utf8)
        #expect(metrics.contains(".scrollContentBackground(.hidden)"))
        #expect(metrics.contains(".background(Color(uiColor: .systemBackground))"))

        let cards = try String(
            contentsOf: root.appending(path: "TFI/UI/Managed/MobileCards.swift"), encoding: .utf8)
        let actionCard = try #require(cards.components(separatedBy: "struct MobileActionCard").last)
        #expect(actionCard.contains(".mobileCardSurface()"))
        #expect(actionCard.contains(".contextMenu {"))
        #expect(cards.contains(".contentShape([.interaction, .contextMenuPreview], shape)"))
        #expect(cards.contains(".containerShape("))
        #expect(!cards.contains(".contentShape(.rect)"))
        #expect(!cards.contains("} preview: {"))
        #expect(!cards.contains("sourceSize"))
        #expect(!cards.contains(".frame(width: 320"))

        let vault = try String(
            contentsOf: root.appending(path: "TFI/Features/Vault/MobileVaultView.swift"), encoding: .utf8)
        #expect(vault.contains("MobileCardPage {"))
        #expect(!vault.contains("List {"))
        #expect(vault.contains("app.library.setExpanded(!isExpanded, for: id)"))
        #expect(vault.contains("app.library.setUngroupedExpanded(!isExpanded)"))

        let workspaceList = try String(
            contentsOf: root.appending(path: "TFI/Features/Workspaces/MobileWorkspaceListView.swift"),
            encoding: .utf8)
        #expect(workspaceList.contains("ContentUnavailableView(\n                \"No Workspaces\""))
        #expect(workspaceList.contains("description: Text(\"Use Connect to start a workspace.\")"))
        #expect(workspaceList.contains("Section(\"History\")"))
        #expect(workspaceList.contains("static let historyLimit = 5"))
        #expect(!workspaceList.contains("Open a host from Vault to start a workspace."))
        #expect(!workspaceList.contains(".buttonStyle(.borderedProminent)"))
        #expect(workspaceList.contains(".buttonStyle(.plain)"))

        let pro = try String(
            contentsOf: root.appending(path: "TFI/Features/Commerce/MobileProView.swift"), encoding: .utf8)
        #expect(!pro.contains("Arrange multiple panes and broadcast input"))
        #expect(pro.contains(".safeAreaInset(edge: .bottom, spacing: 0) { purchaseActions }"))
        #expect(!pro.contains("featureList\n                    purchaseActions"))
        #expect(pro.contains("featureList\n                    secondaryActions"))
        let purchaseActions = try #require(
            pro.components(separatedBy: "private var purchaseActions").last?
                .components(separatedBy: "private var showsPurchase").first)
        #expect(purchaseActions.contains(".frame(maxWidth: .infinity)"))
        #expect(!purchaseActions.contains("secondarySystemGroupedBackground"))
        #expect(!purchaseActions.contains(".overlay"))
    }

    @Test func workspaceMenusUseCompactActionGroups() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspace = try String(
            contentsOf: root.appending(path: "TFI/Features/Workspaces/MobileWorkspaceView.swift"), encoding: .utf8)
        let toolbar = try #require(
            workspace.components(separatedBy: "private var workspaceToolbar").last?
                .components(separatedBy: "private var workspaceSheets").first)
        let branches = toolbar.components(separatedBy: "        if isSFTP {")
        let sshMenu = try #require(branches.first)
        let sftpMenu = try #require(branches.last)
        let sshGroups = sshMenu.components(separatedBy: "                    Divider()\n")
        let sftpGroups = sftpMenu.components(separatedBy: "                    Divider()\n")

        #expect(sshGroups.count == 4)
        #expect(sshGroups[0].contains("Menu {\n                    Button(\"Generate Command\""))
        let snippets = try #require(sshGroups[1].range(of: "Button(\"Snippets\""))
        let history = try #require(sshGroups[1].range(of: "Button(\"History\""))
        let nextMatch = try #require(sshGroups[2].range(of: "Button(\"Next Match\""))
        let previousMatch = try #require(sshGroups[2].range(of: "Button(\"Previous Match\""))
        #expect(snippets.lowerBound < history.lowerBound)
        #expect(nextMatch.lowerBound < previousMatch.lowerBound)
        let sshSameDirectory = try #require(sshGroups[3].range(of: "sameDirectoryMenuAction"))
        let sshRename = try #require(sshGroups[3].range(of: "Button(\"Rename\""))
        let sshClose = try #require(sshGroups[3].range(of: "Button(\"Close\""))
        #expect(sshSameDirectory.lowerBound < sshRename.lowerBound)
        #expect(sshRename.lowerBound < sshClose.lowerBound)

        #expect(sftpGroups.count == 4)
        #expect(sftpGroups[0].contains("Menu {\n                    Button(\"Previous Location\""))
        let previousLocation = try #require(sftpGroups[0].range(of: "Button(\"Previous Location\""))
        let nextLocation = try #require(sftpGroups[0].range(of: "Button(\"Next Location\""))
        #expect(previousLocation.lowerBound < nextLocation.lowerBound)
        let transfers = try #require(sftpGroups[1].range(of: "Button(\"Transfers\""))
        let sftpHistory = try #require(sftpGroups[1].range(of: "Button(\"History\""))
        #expect(transfers.lowerBound < sftpHistory.lowerBound)
        let upload = try #require(sftpGroups[2].range(of: "Button(\"Upload\""))
        let newFolder = try #require(sftpGroups[2].range(of: "Button(\"New Folder\""))
        let paste = try #require(sftpGroups[2].range(of: "Button(\"Paste\""))
        let sort = try #require(sftpGroups[2].range(of: "sortMenu"))
        let hiddenFiles = try #require(
            sftpGroups[2].range(of: "if workspace.sftpSession.showsHiddenFiles"))
        let refresh = try #require(sftpGroups[2].range(of: "Button(\"Refresh\""))
        #expect(!sftpGroups[2].contains("Parent Directory"))
        #expect(sftpGroups[2].contains("Button(\"Hide Hidden Files\", systemImage: \"eye.slash\")"))
        #expect(sftpGroups[2].contains("Button(\"Show Hidden Files\", systemImage: \"eye\")"))
        #expect(upload.lowerBound < newFolder.lowerBound)
        #expect(newFolder.lowerBound < paste.lowerBound)
        #expect(paste.lowerBound < sort.lowerBound)
        #expect(sort.lowerBound < hiddenFiles.lowerBound)
        #expect(hiddenFiles.lowerBound < refresh.lowerBound)
        let sftpSameDirectory = try #require(sftpGroups[3].range(of: "sameDirectoryMenuAction"))
        let sftpRename = try #require(sftpGroups[3].range(of: "Button(\"Rename\""))
        let sftpClose = try #require(sftpGroups[3].range(of: "Button(\"Close\""))
        #expect(sftpSameDirectory.lowerBound < sftpRename.lowerBound)
        #expect(sftpRename.lowerBound < sftpClose.lowerBound)
    }

    @Test func workspaceMenusExposeConditionalSameDirectoryActionsWithoutOwningASeparator() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspace = try String(
            contentsOf: root.appending(path: "TFI/Features/Workspaces/MobileWorkspaceView.swift"), encoding: .utf8)
        let workspaceList = try String(
            contentsOf: root.appending(path: "TFI/Features/Workspaces/MobileWorkspaceListView.swift"),
            encoding: .utf8)
        let rootView = try String(
            contentsOf: root.appending(path: "TFI/App/MobileRootView.swift"), encoding: .utf8)
        let sameDirectoryAction = try #require(
            workspace.components(separatedBy: "private var sameDirectoryMenuAction").last?
                .components(separatedBy: "private var showsJourney").first)

        #expect(workspace.components(separatedBy: "                    sameDirectoryMenuAction").count == 3)
        #expect(workspace.contains("if let launch = workspace.sameDirectoryLaunch"))
        #expect(workspace.contains("Button(\"Open with SSH\", systemImage: \"terminal\")"))
        #expect(workspace.contains("Button(\"Open with SFTP\", systemImage: \"folder\")"))
        #expect(!sameDirectoryAction.contains("Divider()"))
        #expect(
            workspace.components(
                separatedBy: "Button(\"Rename\", systemImage: \"pencil\") { renameWorkspace(workspace) }"
            ).count == 3)
        #expect(workspaceList.contains("Button(\"Rename\", systemImage: \"pencil\")"))
        #expect(rootView.contains("MobileWorkspaceRenameView(workspace: workspace)"))
    }

    @Test func keyGenerationMatchesDesktopDefaultsAndRequiresMatchingPassphrases() throws {
        let app = try MobileAppModel(inMemory: true)
        let editor = MobileKeyEditorModel(mode: .generate, credentials: app.credentials)
        #expect(editor.storage == .iCloud)
        #expect(editor.algorithm == .ed25519)
        #expect(editor.curveBits == 256 && editor.rsaBits == 3072)
        #expect(editor.cipher == .aes256 && editor.rounds == 100)
        #expect(editor.resolvedLabel == "Ed25519" && editor.canSave)
        editor.passphrase = "test-only"
        #expect(!editor.canSave)
        editor.confirmation = "test-only"
        #expect(editor.canSave)
        editor.rounds = 0
        #expect(!editor.canSave)
    }

    @Test func certificateFileImportValidatesKeyMatchingAndLeavesDraftUntouchedOnFailure() async throws {
        let app = try MobileAppModel(inMemory: true)
        let first = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: nil)
        let second = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: nil)
        let key = SSHKeyRef(label: "First", publicKey: first.publicKey)
        let editor = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: key)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = try certificate(publicKey: first.publicKey)
        let file = directory.appending(path: "key-cert.pub")
        try good.write(to: file, atomically: true, encoding: .utf8)
        try await editor.loadCertificateFile(file)
        #expect(editor.certificate == good)
        try certificate(publicKey: second.publicKey).write(to: file, atomically: true, encoding: .utf8)
        await #expect(throws: SSHUserCertificateError.keyMismatch) { try await editor.loadCertificateFile(file) }
        #expect(editor.certificate == good)
    }

    private func certificate(publicKey: String) throws -> String {
        let encoded = try #require(publicKey.split(separator: " ").dropFirst().first)
        let blob = try #require(Data(base64Encoded: String(encoded)))
        // Ed25519 authorized keys contain a method string followed by one 32-byte key.
        let key = Data(blob.suffix(32))
        func u32(_ value: UInt32) -> Data {
            var big = value.bigEndian
            return withUnsafeBytes(of: &big) { Data($0) }
        }
        func u64(_ value: UInt64) -> Data {
            var big = value.bigEndian
            return withUnsafeBytes(of: &big) { Data($0) }
        }
        func field(_ value: Data) -> Data { u32(UInt32(value.count)) + value }
        let method = "ssh-ed25519-cert-v01@openssh.com"
        var certificate = field(Data(method.utf8)) + field(Data("nonce".utf8)) + field(key)
        certificate += u64(42) + u32(1) + field(Data("test".utf8)) + field(Data())
        certificate += u64(0) + u64(UInt64.max)
        for _ in 0..<3 { certificate += field(Data()) }
        certificate += field(Data("ca".utf8)) + field(Data("signature".utf8))
        return "\(method) \(certificate.base64EncodedString())"
    }

}
