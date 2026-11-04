# Manual IME test

The automated tests send what an input method sends, but no real input method ran. This checks the real thing: the candidate window, Escape, and real conversion. It takes about ten minutes. You need Pinyin and Japanese Romaji, which are already enabled on this Mac.

```bash
cd spikes/spike5-ime-undo && swift run -c release spike5-host --interactive
```

The preview is on the left and the source on the right. The terminal prints the buffer after every change, and `>>` lines show composition events. Use the left pane unless a step says otherwise.

**Check after every step:** nothing is duplicated, lost, or reordered, the caret is right after the new text, and the two panes match.

## Pinyin

1. Click in the middle of the first paragraph. Type `nihao`, then press Space to take the first candidate. `你好` appears once.
2. Type `shijie` and press `2` to pick the second candidate. That candidate appears.
3. Type `nihao`, then press Escape. The letters disappear and nothing is added. In the terminal, the buffer shouldn't change at any point while you type the letters.
4. Type `ni`, press Enter. Pinyin commits the letters `ni`, and no new paragraph is created. Press Enter again; now it splits the paragraph.
5. Type a long phrase with several syllables, like `women shi zhongguoren`, and commit it. It lands as one piece.
6. Press Cmd-Z. That composition goes away in one step. Press Cmd-Shift-Z and it comes back.
7. Select a few words across **bold** text, then type `nihao` and commit. The selection is replaced.
8. Select a few words again, type `nihao`, press Escape. The selected words are still there.

## Japanese

Switch to Japanese Romaji.

9. In a list item, type `kanji` and press Space to convert. Press Enter to commit. `漢字` appears once.
10. Type `watashihanihongowohanasu`, press Space, use the left and right arrows to move between clauses, change one clause with Space, then press Enter. The whole sentence lands once, in order.
11. Type `kanji`, press Escape once or twice to back out. Nothing is added.

## Places

12. Compose and commit in each of: a heading, a table cell, a code block, the quote, and at the very end of the last paragraph.
13. Press Enter at the end of a paragraph, and compose on the new empty line.

## Both panes

14. Start composing in the preview without committing. Click into the source pane. The composition should commit or cancel cleanly, with no stray text.
15. Compose and commit in the source pane. It's a plain `NSTextView`, so this should just work, and the preview should update once.
16. Make edits in both panes, then press Cmd-Z repeatedly with focus in the source pane, then in the preview. Each undoes the last edit no matter which pane made it. Keep going until nothing changes; the panes should match the starting text.

## While you're here

17. Cut, copy, and paste in the preview with real content, including from Safari.
18. Does it look stable while typing quickly, with no flicker? (Spike 4 couldn't check this by eye.)

## Report back

Tell me the step numbers that went wrong and what you saw. Copying the terminal output helps. Anything about how it felt is useful too.
