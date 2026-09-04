; ============================================================================
;  helptext.asm -- the help page's title and prompt, in bank 4
; ============================================================================
;  THE COLUMNS ARE NOT HERE. The left one is help_words and the right one is
;  menu_words, both in game/screentext.asm, in bank 7 -- see the top of that
;  file for why the text of every stopped-world screen went there.
;
;  These two strings stayed because they are drawn once each rather than
;  eleven and seventeen times, so a fetch would buy about thirty bytes at the
;  price of a second reason for this page to page a bank; and because
;  help_prompt is SHARED with the squadron page, which draws it with the window
;  at rest. One "ESC - BACK", so the two screens cannot come to disagree about
;  how you get out of them -- the same reasoning that makes the help page's
;  right column BE the orders menu's list.
; ----------------------------------------------------------------------------

;  help_title and help_prompt ARE IN BANK 7 now -- page_words in
;  game/screentext.asm -- fetched through bank7_fetch by help_draw and the
;  squadron page. Nothing but their columns is left here.
