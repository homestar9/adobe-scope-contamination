/**
 * Torture probe model (P4 lock leak). Constructs Thrower inside try/catch in its
 * pseudo-constructor, so a nested construction fails but the outer one succeeds. On the
 * per-class jar Thrower's lock joins this thread's held set and must still be released
 * when Catcher's (outermost) construction returns normally.
 */
component {

	try {
		variables.inner = createObject( "component", "models.torture.Thrower" );
	} catch ( any e ) {
		variables.caught = e.message;
	}

}
