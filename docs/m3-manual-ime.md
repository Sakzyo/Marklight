# Rendered typing in the built app

Open a temporary Markdown file with the text below in the built Marklight app. Choose split view with Cmd-3. Enable Pinyin and Japanese Romaji in macOS Input Sources. Watch the source pane while typing in the preview.

```markdown
# Heading

Before **bold text** and [a link](https://example.com).

- item

> quoted words

z
```

1. Click inside “Before”. In Pinyin, type `nihao`. The candidate window should follow the caret and the source should hold its original text. Press Space to commit. Check that 你好 appears once in both panes. Type `shijie` and choose a numbered candidate. Undo and redo from the preview. The whole composition should move in one step.
2. Select text spanning the bold boundary within the paragraph. Compose, then press Escape. Check that the selected text and its formatting return. Repeat and commit. During a new composition, click into the source pane and back. Check for lost text, stray preedit letters and an unexpected caret jump.
3. Switch to Japanese Romaji. In the list item, type `kanji`, press Space to convert and Enter to commit. Check that 漢字 appears once. Repeat with `watashihanihongowohanasu`, move between clauses and change a candidate before committing. A subsequent plain Enter should beep and preserve both panes.
4. Repeat a commit and a cancel in the heading, quote, bold text and link. A plain link click should place the caret. Cmd-click should open the link. Try another composition in the native source pane and check that the preview follows the commit.
5. Delete the final paragraph’s single `z` with Backspace. Compose into its empty position, commit, delete back to empty, then type again. Repeat with a list item and a quote. Check that the caret remains visible and that deleting at the start beeps.
6. Make several edits in alternating panes, move focus, and undo and redo with Cmd-Z and Cmd-Shift-Z. Check the restored selection in the pane receiving the shortcut. After undoing everything, save and compare the file with the original.
7. In a long document, leave the source pane scrolled away from the active preview paragraph. Type quickly, use arrows, Home, End and the Page keys during typing, and switch focus. Check text order, the next key’s insertion position and scroll stability. Try paste and a cross-block cut. Each refusal should beep without changing either pane.

Record the input source, step, expected and actual text, and what the caret or candidate window did. Typing feel, paint and real input-method candidate selection need a person to assess them.
