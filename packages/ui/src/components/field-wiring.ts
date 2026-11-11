/**
 * Id and ARIA wiring shared by the form controls (T-286).
 *
 * Every control owns its label, hint and error, and derives the description ids itself, so a page
 * never assembles ids by hand and two controls never collide: the base id comes from `$props.id()`,
 * which is unique per component instance and identical between server render and hydration.
 *
 * Read order is hint then error, and an empty text contributes no id at all - a describedby that
 * points at an element that is not rendered is a broken reference for assistive technology.
 */
export interface FieldWiring {
  hintId: string;
  errorId: string;
  describedby: string | undefined;
  invalid: "true" | undefined;
}

export function fieldWiring(id: string, hint: string, error: string): FieldWiring {
  const hintId = `${id}-hint`;
  const errorId = `${id}-error`;

  const describedby =
    [hint === "" ? undefined : hintId, error === "" ? undefined : errorId]
      .filter((value): value is string => value !== undefined)
      .join(" ") || undefined;

  return { hintId, errorId, describedby, invalid: error === "" ? undefined : "true" };
}
