/**
 * Torture probe model (P4 lock leak). Fails because its base (ThrowerBase) throws during
 * extends resolution; the child's own pseudo-constructor never runs in that case.
 */
component extends="models.torture.ThrowerBase" {

	variables.child = true;

}
