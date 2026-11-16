# NoteFlow pour iPhone

App iPhone de [NoteFlow](https://noteflow-silk-kappa.vercel.app) : le site en plein écran, la localisation en arrière-plan et une activité en direct (écran verrouillé, Dynamic Island) avec mini-carte des trajets.

GitHub Actions compile l’app à chaque envoi et publie `NoteFlow.ipa` dans la version [latest](../../releases/tag/latest). Elle s’installe avec SideStore, qui la signe avec ton identifiant Apple.

## Notifications de l’école

La vue web d’une app ne reçoit pas les notifications web (Firebase) du site, et une app installée par SideStore n’a
pas droit aux notifications d’Apple. L’app demande donc elle-même à NoteFlow ce qui est nouveau (toutes les 3 minutes
tant qu’elle tourne, en arrière-plan aussi grâce à la localisation) et l’affiche en notification locale : nouvelle
note, nouvelle information ou sondage, devoirs pour demain (18 h), évaluation dans 3 jours. Réglage : Ma routine ›
Régler › « Notes, informations et devoirs ». Code : `ios/NoteFlow/Inbox.swift`.

## Mode focus : YouTube et Twitch

Ma routine › Régler › « Copier le code de liaison » lie les tweaks ShortLimiter (YouTube) et StreamBoost (Twitch) du
dépôt `short-limiter` : pendant un focus, ces apps sont bloquées en entier, sans raccourci.
