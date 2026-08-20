/**
 * dsh-loopback-pin — pin connection.isLoopback=true in remote browsers.
 *
 * Why: dsh's client refuses Settings/Models unless window.location is loopback
 * (the settings mirror chooses 'memory' persistence). dsh-full-remote's
 * page-bootstrap wraps loader.load once — but rc.8+ REASSIGNS loader.load
 * (to a thin `registration => this.register(registration)` arrow), clobbering
 * the wrap silently (its marker survives, the wrapper does not).
 *
 * This plugin installs an ACCESSOR on loader.load instead: a getter that always
 * returns our intercepting function, and a setter that captures reassignments
 * as the new delegate. The wrap therefore survives any later load reassignment.
 * The connection module's factory is wrapped to pin isLoopback=true on the
 * connection handle right after its apply — before the settings plugin's apply
 * reads it (settings injects connection, so Cordis orders it after).
 *
 * Server-side wire security is unchanged: the /api loopback fence still applies
 * (dsh-full-remote's proxy handles Host/Origin rewriting + auth).
 */
export const name = 'loopback-pin'
export const inject = ['webServer']

const CONN = '@deepseek-ai/dsh-client-connection'

const BOOTSTRAP_SOURCE = [
  '(function(){',
  'var CONN=' + JSON.stringify(CONN) + ';',
  // wrap the connection module's exported apply so the pin runs right after it
  'function wrapApply(fn){',
  'if(!fn||fn.__loopbackPinned)return fn;',
  'function wrapped(ctx){',
  'var result=fn.apply(this,arguments);',
  'function pin(){',
  'try{var c=ctx.get("connection",false);',
  'if(c&&typeof c==="object"){',
  'Object.defineProperty(c,"isLoopback",{value:true,configurable:true,enumerable:true,writable:true});',
  'console.warn("[loopback-pin] pinned connection.isLoopback=true")',
  '}else{console.warn("[loopback-pin] connection handle not found at pin time")}}catch(e){console.warn("[loopback-pin] pin failed",e)}}',
  'if(result&&typeof result.then==="function")return result.then(function(v){pin();return v});',
  'pin();return result}',
  'try{Object.defineProperty(wrapped,"__loopbackPinned",{value:true})}catch(eW){wrapped.__loopbackPinned=true}',
  'return wrapped}',
  'function wrapFactory(h){',
  'var inner=h.factory;',
  'return Object.assign({},h,{factory:function(req){',
  'var mod=inner(req);',
  'try{',
  'if(mod&&typeof mod.apply==="function")mod.apply=wrapApply(mod.apply);',
  'if(mod&&mod.default&&typeof mod.default.apply==="function")mod.default.apply=wrapApply(mod.default.apply);',
  '}catch(e){console.warn("[loopback-pin] export wrap failed",e)}',
  'return mod}})}',
  // accessor-based loader wrap: survives reassignment of .load
  'function installAccessor(loader){',
  'if(!loader||typeof loader.load!=="function"||loader.__loopbackPinActive)return loader;',
  'var origLoad=loader.load;',
  'try{',
  'Object.defineProperty(loader,"load",{',
  'configurable:true,enumerable:true,',
  'get:function(){var self=this;return function(h){',
  'if(h&&h.id===CONN&&typeof h.factory==="function"){',
  'console.warn("[loopback-pin] connection module intercepted");',
  'h=wrapFactory(h)}',
  'return origLoad.call(self,h)}},',
  'set:function(v){if(typeof v==="function"&&!v.__loopbackPassthrough)origLoad=v}});',
  'Object.defineProperty(loader,"__loopbackPinActive",{value:true});',
  'console.warn("[loopback-pin] accessor installed on loader")',
  '}catch(e){console.warn("[loopback-pin] accessor install failed",e)}',
  'return loader}',
  // global slot accessor: wraps every loader object assigned to __ModuleLoader__
  'var current;',
  'try{',
  'current=globalThis.__ModuleLoader__;',
  'Object.defineProperty(globalThis,"__ModuleLoader__",{',
  'configurable:true,enumerable:true,',
  'get:function(){return current},',
  'set:function(v){current=installAccessor(v)}});',
  'if(current)current=installAccessor(current);',
  '}catch(e){console.warn("[loopback-pin] global accessor failed",e)}',
  '})();',
].join('')

const BOOTSTRAP_TAG = `<script data-plugin="dsh-loopback-pin">${BOOTSTRAP_SOURCE}</script>`

function injectBootstrap(html) {
  if (!html.includes('<head>')) return html
  if (html.includes('data-plugin="dsh-loopback-pin"')) return html
  return html.replace('<head>', `<head>${BOOTSTRAP_TAG}`)
}

export function apply(ctx) {
  ctx.effect(() => {
    const untap = ctx.webServer.tapIndex(injectBootstrap)
    try { ctx.logger.info('loopback-pin: bootstrap tap installed') } catch { /* logger optional */ }
    return () => { untap() }
  }, 'loopback-pin')
}
