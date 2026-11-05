# Who is X

A Koreader plugin that helps you remember who a character is. Long-press a name while reading and it shows where that name first appeared and where it last showed up before your current spot.
<table align="center">
  <tr>
    <td align="center" valign="middle">
      <img width="250" alt="Screenshot_2026-11-05-16-30-25-321" src="https://github.com/user-attachments/assets/722b77ed-b967-4b8b-a9d5-525008ae7d64" />
    </td>
    <td align="center" valign="middle">
      <img width="250" alt="Screenshot_2026-11-05-16-30-36-484" src="https://github.com/user-attachments/assets/757506cf-0e45-4624-bee4-fb93b7f1a899" />
    </td>
    <td align="center" valign="middle">
      <img width="250" alt="Screenshot_2026-11-05-16-30-32-595" src="https://github.com/user-attachments/assets/3014600b-5470-4436-b4ad-b67b2e1093fa" />
    </td>
  </tr>
</table>


## How it works

1. Long-press a character's name until the  searching popup shows up.
2. Wait a moment while it searches the book. Tap the screen if you want to cancel.
3. You get a list with the first 3 appearances and the last 3 appearances until the position of your reading.
4. Tap any passage to read it with more context.

## Install

1. Copy the `whoisx.koplugin` folder into KOReader's `plugins` folder.
2. Restart KOReader.

## Settings

You can turn it on or off from the top menu, open a book and go to the second tab Document ("Who is X"). It's on by default.

## Good to know

- Only works with reflowable books.
- Nothing is saved or cached. It does nothing until you trigger a search, and everything is dropped when you close the windows.
- On very long books and slow e-readers the search can take a while, since Koreader has to scan the text. The plugin stops as soon as it has what it needs, so it's faster when you're earlier in the book.
- Searches are capped at 5000 matches.

