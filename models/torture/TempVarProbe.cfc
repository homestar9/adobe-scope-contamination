/**
 * Temp-variable probe (P8). A WireBox SINGLETON, so one instance and one `variables` scope are
 * shared by every request, exactly like WireBox's own Builder and Injector.
 *
 * Adobe's fourth hotfix (v4) changes one thing in NeoPageContext: the compiler's temporary for
 * an inline struct or array literal (`___IMPLICITARRYSTRUCTVAR<n>`) is kept in the running
 * function's LOCAL scope when it was not declared there. The compiler declares that temporary
 * for a literal in a plain statement, but NOT for a literal inside a conditional expression
 * (`cond ? { ... } : { ... }`, `x ?: { ... }`). On every earlier build such a temporary is
 * written to the component's VARIABLES scope, the usual fate of an un-`var`ed name. In a
 * transient that is only a stray key. In a singleton it is one slot shared by every concurrent
 * request: request A creates its struct and stores it in the slot, request B overwrites the slot
 * with its own struct, and A reads the slot back to fill in its keys and return it. A now holds
 * B's struct. WireBox's Builder.buildCFC builds its constructor argument collection with exactly
 * that shape: `constructorArgs.len() ? buildArgumentCollection( ... ) : {}`.
 *
 * Each builder below uses the conditional shape and widens the window with a slow call inside
 * the literal. The handler checks that the value each thread gets back carries its own token,
 * and leakedKeys() shows whether the temporaries landed in this singleton's variables scope.
 */
component singleton {

	function init() {
		return this;
	}

	/** A struct literal inside a conditional expression; the slow value sits between the temporary's write and its read-back. */
	struct function build( required string token, numeric sleepMs = 2, boolean other = false ) {
		return arguments.other ? {} : { "token" : slowValue( arguments.token, arguments.sleepMs ), "again" : arguments.token };
	}

	/** An array literal inside a conditional expression, same idea. */
	array function buildArray( required string token, numeric sleepMs = 2, boolean other = false ) {
		return arguments.other ? [] : [ slowValue( arguments.token, arguments.sleepMs ), arguments.token ];
	}

	/**
	 * The WireBox shape: a conditional struct literal passed straight into invoke() as the
	 * argument collection (Builder.buildCFC does `invoke( oModel, "init", constructorArgCollection )`).
	 */
	string function buildViaInvoke( required string token, numeric sleepMs = 2, boolean other = false ) {
		return invoke( this, "echo", arguments.other ? {} : { "token" : slowValue( arguments.token, arguments.sleepMs ) } );
	}

	string function echo( required string token ) {
		return arguments.token;
	}

	/** Every key of this singleton's variables scope that is a leaked compiler temporary. */
	array function leakedKeys() {
		var found = [];
		for ( var key in structKeyArray( variables ) ) {
			if ( left( key, 11 ) == "___IMPLICIT" ) {
				found.append( key );
			}
		}
		return found;
	}

	numeric function variablesKeyCount() {
		return structCount( variables );
	}

	private string function slowValue( required string value, required numeric sleepMs ) {
		if ( arguments.sleepMs > 0 ) {
			sleep( arguments.sleepMs );
		}
		return arguments.value;
	}

}
