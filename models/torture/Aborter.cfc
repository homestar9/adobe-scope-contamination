/**
 * Torture probe model (P4 lock leak, abort path). Executes `abort` in its pseudo-constructor
 * while request.tortureAbort is true. abort unwinds through resolveName as a special
 * exception that userland catch blocks do not see; the lock must still be released. Only
 * ever constructed inside a dedicated cfthread, where abort ends that thread, never the
 * request.
 */
component {

	if ( structKeyExists( request, "tortureAbort" ) && request.tortureAbort ) {
		abort;
	}
	variables.built = true;

}
