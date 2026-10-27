# Detective Math Online

A browser-based multiplayer Grade 1 math mystery game using Supabase Realtime and Vercel.

## Implemented behavior

- Teacher-authenticated room creation with a manually chosen 4–10 character code.
- Four unique player seats: Conan, Ai, Mitsuhiko, and Genta.
- Teacher starts the game only after all four characters have joined.
- Fixed turn order: Conan → Ai → Mitsuhiko → Genta, repeated across 20 questions.
- Only the active player can submit an answer; everyone can see the roster and active turn.
- Students can select an answer and change it before confirming.
- Correct answers earn 1 point. A correct answer within 10 seconds after the active player presses Continue earns 1 additional speed point. No countdown timer is shown.
- Wrong answers reveal the correct answer and advance to the next player.
- Late arrivals can join as spectators and cannot answer.
- Teacher dashboard shows rooms, player roster, current turn, and scores, and can start or end a mission.
- Reconnecting players can resume from the same browser using a locally saved session.
- English questions and answer choices; the interface includes Arabic instructions where provided by the page design.

## Supabase

The browser uses public/config.js with the project's publishable/anon key only. Never put a service-role key in client code.

Database changes are tracked under supabase/migrations/. Teacher RPCs require an authenticated user with app_metadata.role = "teacher".

## Deployment and testing

Vercel is connected to the main branch and uses public as its output directory. A successful deployment build does not by itself prove a complete four-browser game session. Before classroom use, test with four separate browser sessions:

1. Sign in as a teacher and create a room code.
2. Join as Conan, Ai, Mitsuhiko, and Genta from four separate sessions.
3. Confirm the teacher dashboard stays in the waiting state until all four players join.
4. Start the mission from the teacher dashboard.
5. Confirm only the active character can answer and the order repeats exactly.
6. Test answer editing before confirmation, correct/incorrect answers, speed bonus, spectator entry, reconnect, and teacher end-game.

## Character artwork

Character cards currently use emoji placeholders. Replace them with artwork only when the assets are provided by the user or verified as licensed for reuse; do not assume images found online are free to redistribute.
