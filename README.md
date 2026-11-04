# card-export

The flashcard plumbing that [readq](https://github.com/n0w1ht/readq) and
[dict-lookup](https://github.com/n0w1ht/dict-lookup) share: sending cards to
Anki, and making Org entries into [org-srs](https://github.com/bohonghuang/org-srs)
cards. Each tool still decides what goes on its cards; card-export only
delivers them.

You don't use it directly. Install it next to readq or dict-lookup:

```elisp
(add-to-list 'load-path "~/path/to/card-export")
```

## Setting

| Option | Default | |
|---|---|---|
| `card-export-anki-connect-url` | `http://127.0.0.1:8765` | where the [AnkiConnect](https://ankiweb.net/shared/info/2055492159) add-on listens |

It replaces `readq-anki-connect-url` and `dict-lookup-anki-connect-url`,
which still work as old names for it.

## For tools making cards

Anki:

- `card-export-anki`: call an AnkiConnect action.
- `card-export-anki-reachable-p`: is Anki running, with AnkiConnect?
- `card-export-anki-add-notes`: add notes and their images. Returns, for
  each note, its Anki id, `duplicate`, or `(error . MESSAGE)`.
- `card-export-anki-send`: add notes through AnkiConnect, or, when Anki
  isn't running, offer to write the import file instead.
- `card-export-anki-update-changed`: given cards with their Anki id and
  the hash of what was sent, update the ones that changed since. The
  caller keeps the ids and hashes wherever it likes.
- `card-export-anki-update-notes`: replace the fields of notes Anki
  already has (their `:id`), leaving deck, note type, tags and reviews.
  Returns, for each note, `t`, `missing` (deleted in Anki), or
  `(error . MESSAGE)`. Anki doesn't update a note open in its Browse
  window.
- `card-export-note-hash`: a hash of a note's fields and images. Keep it
  with the note's id, and update the note only when it changes.
- `card-export-anki-write-file`: append notes to a file for Anki's
  File > Import, when Anki isn't running.
- `card-export-anki-copy-media`: copy images to Anki's `collection.media`,
  since an import file can't carry them.
- `card-export-html-escape`: plain text for a field.
- `card-export-org-to-html`: Org text for a field, with lists, tables,
  emphasis and links.
- `card-export-markdown-to-html`: inline Markdown (`**bold**`, `*italic*`,
  `` `code` ``) for a field, such as an AI model's answer.

For cards that are Org entries, one function does all of it:

- `card-export-anki-org-export`: given the entries and a function that
  makes an entry's note, it updates the entries edited since they were
  sent, adds the new ones (or offers the import file when Anki isn't
  running), and records on each entry what Anki has of it:

  | Property | |
  |---|---|
  | `ANKI_EXPORTED` | when it was sent or written to the import file |
  | `ANKI_NOTE_ID` | its Anki note, or `duplicate` |
  | `ANKI_HASH` | what was sent, to tell later whether it changed |

  A card whose note was deleted in Anki is added again once you edit it.
  dict-lookup uses this for `vocabulary.org`.

A note is a plist:

```elisp
(:deck "Deck::Subdeck" :model "Basic"
 :fields (("Front" . "<b>HTML</b>") ("Back" . "HTML"))
 :tags ("tag")
 :media (("name-in-anki.png" . "/path/to/file.png"))
 :id 1496198395707)                     ; only to update a note
```

org-srs, with point on the card's Org entry:

- `card-export-srs-available-p`: is org-srs installed?
- `card-export-org-body`: text safe for an entry's body (a line starting
  with `*` would start a heading).
- `card-export-markdown-to-org`: inline Markdown to Org markup.
- `card-export-srs-make-card`: the heading asks; a `Back` subheading
  answers.
- `card-export-srs-make-cloze-card`: one review item per cloze id, for
  clozes written `{{1}{hidden}{hint}}`.
- `card-export-anki-cloze-to-srs` and `card-export-anki-cloze-ids`:
  convert clozes written the Anki way, `{{c1::hidden::hint}}`.

Clozes written the Anki way:

- `card-export-anki-cloze`: a command that makes the selection a cloze,
  `{{text}}`, or with a prefix argument `{{text::hint}}`. readq binds it
  to `C-c r k`.
- `card-export-anki-number-clozes`: `{{x}}` to `{{c1::x}}`, `{{c2::…}}`,
  keeping clozes numbered already.

## Running the tests

```sh
emacs -Q --batch -L . -l test/card-export-test.el -f ert-run-tests-batch-and-exit
```

The org-srs tests run when org-srs and `fsrs` are on the load path
(`-L /path/to/org-srs -L /path/to/fsrs`).
