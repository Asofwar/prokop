// language=CSS
export const styles = `
.fkp-autotune {
    display: flex;
    flex-direction: column;
    gap: var(--fkp-space-3);
    min-width: 0;
}
.fkp-autotune__card {
    display: flex;
    flex-direction: column;
    gap: var(--fkp-space-2);
    min-width: 0;
    padding: var(--fkp-space-3) var(--fkp-space-4);
    border: 1px solid var(--fkp-border);
    border-radius: 6px;
}
.fkp-autotune__head {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: var(--fkp-space-2);
}
.fkp-autotune__title { margin: 0; font-size: 1.05em; min-width: 0; overflow-wrap: anywhere; }
.fkp-autotune__hint,
.fkp-autotune__muted { margin: 0; color: var(--fkp-tone-neutral); overflow-wrap: anywhere; }
.fkp-autotune__text { margin: 0; overflow-wrap: anywhere; }
.fkp-autotune__alert {
    padding: var(--fkp-space-2) var(--fkp-space-3);
    border: 1px solid var(--fkp-tone-error);
    border-left-width: 4px;
    border-radius: 6px;
    overflow-wrap: anywhere;
}
.fkp-autotune__alert p { margin: var(--fkp-space-1) 0 var(--fkp-space-2); }
.fkp-autotune__modes { display: flex; flex-wrap: wrap; gap: var(--fkp-space-1); }
.fkp-autotune__modes .btn[aria-pressed="true"] {
    font-weight: 600;
    border-color: var(--fkp-tone-loading);
    outline: 2px solid var(--fkp-tone-loading);
    outline-offset: 1px;
}
.fkp-autotune__facts {
    display: grid;
    grid-template-columns: max-content minmax(0, 1fr);
    gap: var(--fkp-space-1) var(--fkp-space-4);
    margin: 0;
}
.fkp-autotune__facts dt { font-weight: 600; }
.fkp-autotune__facts dd { margin: 0; min-width: 0; overflow-wrap: anywhere; }
.fkp-autotune__list { margin: 0; padding: 0; list-style: none; }
.fkp-autotune__group {
    display: flex;
    flex-direction: column;
    gap: var(--fkp-space-2);
    min-width: 0;
    padding: var(--fkp-space-3) 0;
    border-top: 1px solid var(--fkp-border);
}
.fkp-autotune__group:first-child { border-top: 0; padding-top: 0; }
.fkp-autotune__row {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--fkp-space-1) var(--fkp-space-3);
    min-width: 0;
}
.fkp-autotune__name { font-weight: 600; flex: 1 1 200px; min-width: 0; overflow-wrap: anywhere; }
.fkp-autotune__progress { display: inline-flex; gap: 3px; vertical-align: middle; }
/* A running check. */
.fkp-autotune__run { display: grid; gap: var(--fkp-space-1); min-width: 0; }
.fkp-autotune__bar { height: 6px; border-radius: 3px; background: var(--fkp-border); overflow: hidden; max-width: 480px; }
.fkp-autotune__bar > div { height: 100%; background: var(--fkp-tone-loading); transition: width 0.5s; }
.fkp-autotune__run-items { list-style: none; margin: 0; padding: 0; }
.fkp-autotune__run-item { display: flex; flex-wrap: wrap; align-items: center; gap: var(--fkp-space-1) var(--fkp-space-2); padding: 2px 0; min-width: 0; }
.fkp-autotune__run-item--pending { color: var(--fkp-tone-neutral); }
.fkp-autotune__run-icon { width: 1em; text-align: center; flex: none; }
.fkp-autotune__run-item .fkp-autotune__what { flex: 0 1 16em; }
.fkp-autotune__dot {
    width: 0.7em;
    height: 0.7em;
    border-radius: 50%;
    border: 1px solid var(--fkp-tone-loading);
}
.fkp-autotune__dot--on { background: var(--fkp-tone-loading); }
.fkp-autotune__item {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--fkp-space-1) var(--fkp-space-3);
    padding: var(--fkp-space-2) 0;
    border-top: 1px solid var(--fkp-border);
    min-width: 0;
}
.fkp-autotune__item:first-child { border-top: 0; }
/* Choosing pinned domains of a list: a scrollable list of checkboxes. */
.fkp-autotune__domains { max-height: 240px; overflow-y: auto; margin-top: var(--fkp-space-1); padding: var(--fkp-space-1) var(--fkp-space-2); border: 1px solid var(--fkp-border); border-radius: 4px; }
.fkp-autotune__domain { display: flex; align-items: center; gap: var(--fkp-space-1); padding: 2px 0; overflow-wrap: anywhere; font-weight: normal; }
/* The domains of a list target, under it and indented. */
.fkp-autotune__members { flex: 1 1 100%; min-width: 0; padding-left: var(--fkp-space-3); border-left: 2px solid var(--fkp-border); }
.fkp-autotune__what { flex: 1 1 240px; min-width: 0; overflow-wrap: anywhere; }
.fkp-autotune__time { color: var(--fkp-tone-neutral); min-width: 0; }
.fkp-autotune__table-wrap { width: 0; min-width: 100%; overflow-x: auto; }
.fkp-autotune__table { width: 100%; }
.fkp-autotune__table td { overflow-wrap: anywhere; vertical-align: top; }
.fkp-autotune__form {
    display: grid;
    grid-template-columns: max-content minmax(0, 1fr);
    gap: var(--fkp-space-2) var(--fkp-space-3);
    align-items: center;
}
.fkp-autotune__form input,
.fkp-autotune__form select { width: 100%; min-width: 0; box-sizing: border-box; }
/* The checkboxes of the domain list keep their own size; the domain reads left to right. */
.fkp-autotune__form .fkp-autotune__domain { text-align: left; justify-content: flex-start; width: 100%; }
.fkp-autotune__form .fkp-autotune__domain input { width: auto; flex: none; margin: 0; }
.fkp-autotune__field-hint { grid-column: 2; margin-top: calc(-1 * var(--fkp-space-1)); color: var(--fkp-tone-neutral); font-size: 0.9em; }

@media (max-width: 599px) {
    .fkp-autotune__facts,
    .fkp-autotune__form { grid-template-columns: minmax(0, 1fr); }
    .fkp-autotune__facts dd { margin-bottom: var(--fkp-space-2); }
    .fkp-autotune__field-hint { grid-column: 1; }
}
`;
