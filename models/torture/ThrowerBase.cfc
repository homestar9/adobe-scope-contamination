/**
 * Torture probe model (P4 lock leak). Ancestor of ThrowerChild whose pseudo-constructor
 * throws while request.tortureBaseThrows is true. The throw happens inside the NESTED
 * resolveName for the base, while the child's lock is already held, so this exercises the
 * "only the outermost call unlocks" path of the per-class jar.
 */
component {

	if ( structKeyExists( request, "tortureBaseThrows" ) && request.tortureBaseThrows ) {
		throw( type = "Torture.ThrowerBase", message = "ThrowerBase: deliberate ancestor pseudo-constructor failure" );
	}
	variables.base = true;

}
