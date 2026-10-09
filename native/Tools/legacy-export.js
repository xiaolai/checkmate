// Run in the legacy Checkmate window's Web Inspector console. This reads only
// Checkmate's progress/settings keys and does not include account credentials.
(() => {
  const keys = ['checkmate-practice-pgn','checkmate-previous-game','checkmate-settings-v1','checkmate-course-v1','checkmate-puzzles-v1','checkmate-progress','checkmate-companion-preferences-v1'];
  const values = Object.fromEntries(keys.flatMap(key => {const value=localStorage.getItem(key);return value===null?[]:[[key,value]]}));
  return JSON.stringify({format:'checkmate-legacy-export',version:1,values},null,2);
})()
