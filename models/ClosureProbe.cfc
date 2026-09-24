/**
 * A transient that builds and calls closures during construction.
 *
 * The hotfix replaces coldfusion.runtime.Closure and adds capturedOwner / capturedVarScope
 * to it, so closures now hold onto their owner's variable scope instead of picking up
 * whatever scope happens to be current. Nothing in ConstructionProbe or WideProbe touches
 * that code, so without this probe the changed Closure class is never measured.
 *
 * Keeps the same setValue/getValue contract as the other probes.
 */
component {

	variables.value   = 0;
	variables.adder   = "";
	variables.doubler = "";
	variables.tally   = 0;

	function init() {
		// Closures created here capture this instance's variables scope, which is the
		// path the hotfix changed.
		variables.adder = function( required numeric n ) {
			return variables.tally + arguments.n;
		};

		variables.doubler = function( required numeric n ) {
			return arguments.n * 2;
		};

		variables.tally = variables.doubler( 1 );
		return this;
	}

	function setValue( required numeric value ) {
		// Route the write through the closures so they are actually invoked, not just built.
		variables.value = variables.adder( arguments.value ) - variables.tally;
		return this;
	}

	numeric function getValue() {
		return variables.value;
	}

	function getTally() {
		return variables.tally;
	}

}
