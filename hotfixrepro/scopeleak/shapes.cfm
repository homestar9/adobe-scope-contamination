<cfscript>
/*
 * Diagnostic: which code shapes leave the compiler's literal temporary in the component's
 * variables scope? Runs every method of Shapes.cfc once on one instance (single-threaded) and
 * prints the ___IMPLICIT keys left behind by each. Any shape that lists keys here is a shape that
 * shares its half-built literal between concurrent requests on a singleton (before the fourth
 * hotfix).
 */
probe = createObject( "component", "Shapes" );
md = getMetadata( probe );
rows = [];
for ( f in md.functions ) {
	if ( listFindNoCase( "leakedKeys,clearLeaked,echoStruct,defaultArgLiteral", f.name ) ) continue;
	probe.clearLeaked();
	err = "";
	try { invoke( probe, f.name ); } catch ( any e ) { err = e.message; }
	keys = probe.leakedKeys();
	rows.append( { "shape" : f.name, "leaked" : keys.len(), "keys" : arrayToList( keys ), "error" : err } );
}
rows.sort( function( a, b ){ return compare( a.shape, b.shape ); } );
if ( url.keyExists( "json" ) ) {
	cfheader( name="Content-Type", value="application/json" );
	writeOutput( serializeJSON( { "server" : server.coldfusion.productVersion, "shapes" : rows } ) );
	abort;
}
writeOutput( "<h2>Literal temporaries left in variables, by code shape</h2><p>Server: #encodeForHTML( server.coldfusion.productVersion )#</p><table border=1 cellpadding=4><tr><th>shape</th><th>leaked</th><th>keys</th><th>error</th></tr>" );
for ( r in rows ) {
	writeOutput( "<tr><td>#r.shape#</td><td>#r.leaked#</td><td>#encodeForHTML( r.keys )#</td><td>#encodeForHTML( r.error )#</td></tr>" );
}
writeOutput( "</table>" );
</cfscript>
