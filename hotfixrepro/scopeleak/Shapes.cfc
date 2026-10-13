/**
 * Which code shapes make the compiler's literal temporary land in the component's variables
 * scope? Each method builds an inline literal in one shape. shapes.cfm calls each one on a single
 * shared instance and reports the ___IMPLICIT keys left in `variables` afterwards.
 */
component {

	function plainStruct() { return { "a" : 1 }; }
	function plainArray() { return [ 1, 2 ]; }
	function nestedStruct() { return { "a" : { "b" : [ 1, { "c" : 2 } ] } }; }
	function ternaryFalseBranch( boolean flag = false ) { return arguments.flag ? plainStruct() : {}; }
	function ternaryTrueBranch( boolean flag = true ) { return arguments.flag ? { "a" : 1 } : {}; }
	function ternaryBothLiterals( boolean flag = false ) { return arguments.flag ? { "a" : 1 } : { "b" : 2 }; }
	function ternaryInVar( boolean flag = false ) { var s = arguments.flag ? plainStruct() : {}; return s; }
	function ternaryEmptyArray( boolean flag = false ) { return arguments.flag ? [ 1 ] : []; }
	function elvis() { var x = javaCast( "null", "" ); return x ?: { "a" : 1 }; }
	function nullCoalesceCall() { return isNull( variables.nothing ) ? { "a" : 1 } : variables.nothing; }
	function closureBody() { var f = function(){ return { "a" : 1 }; }; return f(); }
	function arrowBlockBody() { var f = () => { return { "a" : 1 }; }; return f(); }
	function closureArgLiteral() { return [ 1, 2 ].map( function( v ){ return { "v" : v }; } ); }
	function reduceInitialLiteral() { return [ 1, 2 ].reduce( function( r, v ){ r.n += v; return r; }, { "n" : 0 } ); }
	function callArgLiteral() { return structCount( { "a" : 1, "b" : 2 } ); }
	function nestedCallArgLiteral() { return structCount( structCopy( { "a" : 1 } ) ); }
	function structAppendLiterals() { var s = {}; structAppend( s, { "a" : 1 }, true ); return s; }
	function inLoop() { var s = {}; for ( var i = 1; i <= 3; i++ ) { s = { "i" : i }; } return s; }
	function inLoopVar() { for ( var i = 1; i <= 3; i++ ) { var s = { "i" : i }; } return s; }
	function inIf() { if ( true ) { var s = { "a" : 1 }; return s; } return {}; }
	function inTry() { try { var s = { "a" : 1 }; return s; } catch ( any e ) { return {}; } }
	function inSwitch( string k = "x" ) { switch ( arguments.k ) { case "x": return { "a" : 1 }; default: return {}; } }
	function unscopedAssign() { s = { "a" : 1 }; return s; }
	function defaultArgLiteral( struct opts = {} ) { return arguments.opts; }
	function defaultArgLiteralCall() { return defaultArgLiteral(); }
	function returnDirect() { return { "token" : "x" }; }
	function invokeArgLiteral() { return invoke( this, "echoStruct", { "a" : 1 } ); }
	function echoStruct( required struct s ) { return arguments.s; }
	function lockBlock() { lock name="shapes-l" type="exclusive" timeout="2" { var s = { "a" : 1 }; } return s; }
	function methodChainLiteral() { return { "a" : 1 }.keyArray(); }
	function stringInterpolation() { var t = "x"; return { "a" : "v-#t#" }; }
	function literalInWhile() { var i = 0; var s = {}; while ( i < 2 ) { i++; s = { "i" : i }; } return s; }
	function literalInsideClosureInTernary( boolean flag = false ) { var f = function(){ return arguments.flag ? {} : { "a" : 1 }; }; return f(); }
	function ternaryCallArg( boolean flag = false ) { return structCount( arguments.flag ? { "a" : 1 } : {} ); }
	function ternaryInStructAppend( boolean flag = false ) { var s = { "z" : 0 }; structAppend( s, arguments.flag ? {} : { "a" : 1 }, true ); return s; }

	array function leakedKeys() {
		var found = [];
		for ( var key in structKeyArray( variables ) ) {
			if ( left( key, 11 ) == "___IMPLICIT" ) found.append( key );
		}
		return found;
	}

	void function clearLeaked() {
		for ( var key in leakedKeys() ) structDelete( variables, key );
	}

}
