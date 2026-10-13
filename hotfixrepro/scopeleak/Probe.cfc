/**
 * One shared instance of this component stands in for any singleton (a framework builder, a
 * service, a cached helper). Each builder returns an inline struct or array literal written
 * inside a conditional expression (`cond ? {} : { ... }`), the shape whose compiler temporary is
 * not declared as a local, and whose first value comes from a slow call, which widens the window
 * between the temporary's write and its read-back. leakedKeys() lists the compiler temporaries
 * that ended up in this instance's variables scope. Shapes.cfc / shapes.cfm show which code
 * shapes leak and which do not.
 */
component {

	struct function build( required string token, numeric sleepMs = 2, boolean other = false ) {
		return arguments.other ? {} : { "token" : slowValue( arguments.token, arguments.sleepMs ), "again" : arguments.token };
	}

	array function buildArray( required string token, numeric sleepMs = 2, boolean other = false ) {
		return arguments.other ? [] : [ slowValue( arguments.token, arguments.sleepMs ), arguments.token ];
	}

	string function buildViaInvoke( required string token, numeric sleepMs = 2, boolean other = false ) {
		return invoke( this, "echo", arguments.other ? {} : { "token" : slowValue( arguments.token, arguments.sleepMs ) } );
	}

	string function echo( required string token ) {
		return arguments.token;
	}

	array function leakedKeys() {
		var found = [];
		for ( var key in structKeyArray( variables ) ) {
			if ( left( key, 11 ) == "___IMPLICIT" ) {
				found.append( key );
			}
		}
		return found;
	}

	private string function slowValue( required string value, required numeric sleepMs ) {
		if ( arguments.sleepMs > 0 ) {
			sleep( arguments.sleepMs );
		}
		return arguments.value;
	}

}
