(window.webpackJsonp=window.webpackJsonp||[]).push([[30],{762:function(e,t,a){"use strict";a.d(t,"a",(function(){return j}));var i,o,s=a(0),n=a(2),r=a(7),c=a(1),u=a(13),d=a(3),l=a.n(d),b=a(6),g=a(316),f=a(20),m=a(711),p=a(47),v=Object(b.f)({logoutMessage:{id:"confirmations.logout.message",defaultMessage:"Are you sure you want to log out?"},logoutConfirm:{id:"confirmations.logout.confirm",defaultMessage:"Log out"}}),j=(i=Object(u.connect)(null,(function(e,t){var a=t.intl;return{onLogout:function(){e(Object(p.d)("CONFIRM",{message:a.formatMessage(v.logoutMessage),confirm:a.formatMessage(v.logoutConfirm),onConfirm:function(){return Object(m.a)()}}))}}})),Object(b.g)(o=i(o=function(e){function t(){for(var t,a=arguments.length,i=new Array(a),o=0;o<a;o++)i[o]=arguments[o];return t=e.call.apply(e,[this].concat(i))||this,Object(c.a)(Object(n.a)(t),"handleLogoutClick",(function(e){return e.preventDefault(),e.stopPropagation(),t.props.onLogout(),!1})),t}return Object(r.a)(t,e),t.prototype.render=function(){var e=this.props.withHotkeys;return Object(s.a)("div",{className:"getting-started__footer"},void 0,Object(s.a)("ul",{},void 0,f.j&&Object(s.a)("li",{},void 0,Object(s.a)("a",{href:"/invites",target:"_blank"},void 0,Object(s.a)(b.b,{id:"getting_started.invite",defaultMessage:"Invite people"}))," · "),e&&Object(s.a)("li",{},void 0,Object(s.a)(g.a,{to:"/keyboard-shortcuts"},void 0,Object(s.a)(b.b,{id:"navigation_bar.keyboard_shortcuts",defaultMessage:"Hotkeys"}))," · "),Object(s.a)("li",{},void 0,Object(s.a)("a",{href:"/auth/edit"},void 0,Object(s.a)(b.b,{id:"getting_started.security",defaultMessage:"Security"}))," · "),Object(s.a)("li",{},void 0,Object(s.a)("a",{href:"/about/more",target:"_blank"},void 0,Object(s.a)(b.b,{id:"navigation_bar.info",defaultMessage:"About this server"}))," · "),Object(s.a)("li",{},void 0,Object(s.a)("a",{href:"https://joinmastodon.org/apps",target:"_blank"},void 0,Object(s.a)(b.b,{id:"navigation_bar.apps",defaultMessage:"Mobile apps"}))," · "),Object(s.a)("li",{},void 0,Object(s.a)("a",{href:"/terms",target:"_blank"},void 0,Object(s.a)(b.b,{id:"getting_started.terms",defaultMessage:"Terms of service"}))," · "),Object(s.a)("li",{},void 0,Object(s.a)("a",{href:"/settings/applications",target:"_blank"},void 0,Object(s.a)(b.b,{id:"getting_started.developers",defaultMessage:"Developers"}))," · "),Object(s.a)("li",{},void 0,Object(s.a)("a",{href:"https://docs.joinmastodon.org",target:"_blank"},void 0,Object(s.a)(b.b,{id:"getting_started.documentation",defaultMessage:"Documentation"}))," · "),Object(s.a)("li",{},void 0,Object(s.a)("a",{href:"/auth/sign_out",onClick:this.handleLogoutClick},void 0,Object(s.a)(b.b,{id:"navigation_bar.logout",defaultMessage:"Logout"})))),Object(s.a)("p",{},void 0,Object(s.a)(b.b,{id:"getting_started.open_source_notice",defaultMessage:"Mastodon is open source software. You can contribute or report issues on GitHub at {github}.",values:{github:Object(s.a)("span",{},void 0,Object(s.a)("a",{href:f.t,rel:"noopener noreferrer",target:"_blank"},void 0,f.q)," (v",f.y,")")}})))},t}(l.a.PureComponent))||o)||o)},790:function(e,t,a){"use strict";a.r(t),a.d(t,"default",(function(){return x}));var i,o,s,n=a(0),r=a(7),c=a(1),u=(a(3),a(731)),d=a(1140),l=a(1141),b=a(6),g=a(13),f=a(5),m=a.n(f),p=a(14),v=a.n(p),j=a(18),O=a(20),h=a(25),_=a(4),M=a(756),y=a(26),k=a(762),w=a(839),q=Object(b.f)({home_timeline:{id:"tabs_bar.home",defaultMessage:"Home"},notifications:{id:"tabs_bar.notifications",defaultMessage:"Notifications"},public_timeline:{id:"navigation_bar.public_timeline",defaultMessage:"Federated timeline"},settings_subheading:{id:"column_subheading.settings",defaultMessage:"Settings"},community_timeline:{id:"navigation_bar.community_timeline",defaultMessage:"Local timeline"},direct:{id:"navigation_bar.direct",defaultMessage:"Direct messages"},bookmarks:{id:"navigation_bar.bookmarks",defaultMessage:"Bookmarks"},preferences:{id:"navigation_bar.preferences",defaultMessage:"Preferences"},follow_requests:{id:"navigation_bar.follow_requests",defaultMessage:"Follow requests"},favourites:{id:"navigation_bar.favourites",defaultMessage:"Favourites"},blocks:{id:"navigation_bar.blocks",defaultMessage:"Blocked users"},domain_blocks:{id:"navigation_bar.domain_blocks",defaultMessage:"Hidden domains"},mutes:{id:"navigation_bar.mutes",defaultMessage:"Muted users"},pins:{id:"navigation_bar.pins",defaultMessage:"Pinned toots"},lists:{id:"navigation_bar.lists",defaultMessage:"Lists"},discover:{id:"navigation_bar.discover",defaultMessage:"Discover"},personal:{id:"navigation_bar.personal",defaultMessage:"Personal"},security:{id:"navigation_bar.security",defaultMessage:"Security"},menu:{id:"getting_started.heading",defaultMessage:"Getting started"},profile_directory:{id:"getting_started.directory",defaultMessage:"Profile directory"}}),x=Object(g.connect)((function(e){return{myAccount:e.getIn(["accounts",O.n]),unreadFollowRequests:e.getIn(["user_lists","follow_requests","items"],Object(_.List)()).size}}),(function(e){return{fetchFollowRequests:function(){return e(Object(h.B)())}}}))(i=Object(b.g)((s=o=function(e){function t(){return e.apply(this,arguments)||this}Object(r.a)(t,e);var a=t.prototype;return a.componentDidMount=function(){var e=this.props,t=e.fetchFollowRequests;!e.multiColumn&&window.innerWidth>=1190?this.context.router.history.replace("/timelines/home"):t()},a.render=function(){var e,t,a=this.props,i=a.intl,o=a.myAccount,s=a.multiColumn,r=a.unreadFollowRequests,c=[],g=1,f=s?0:60;return s?(c.push(Object(n.a)(l.a,{text:i.formatMessage(q.discover)},g++),Object(n.a)(d.a,{icon:"users",text:i.formatMessage(q.community_timeline),to:"/timelines/public/local"},g++),Object(n.a)(d.a,{icon:"globe",text:i.formatMessage(q.public_timeline),to:"/timelines/public"},g++)),f+=130,O.o&&(c.push(Object(n.a)(d.a,{icon:"address-book",text:i.formatMessage(q.profile_directory),to:"/directory"},g++)),f+=48),c.push(Object(n.a)(l.a,{text:i.formatMessage(q.personal)},g++)),f+=34):O.o&&(c.push(Object(n.a)(d.a,{icon:"address-book",text:i.formatMessage(q.profile_directory),to:"/directory"},g++)),f+=48),c.push(Object(n.a)(d.a,{icon:"envelope",text:i.formatMessage(q.direct),to:"/timelines/direct"},g++),Object(n.a)(d.a,{icon:"bookmark",text:i.formatMessage(q.bookmarks),to:"/bookmarks"},g++),Object(n.a)(d.a,{icon:"star",text:i.formatMessage(q.favourites),to:"/favourites"},g++),Object(n.a)(d.a,{icon:"list-ul",text:i.formatMessage(q.lists),to:"/lists"},g++)),f+=192,(o.get("locked")||r>0)&&(c.push(Object(n.a)(d.a,{icon:"user-plus",text:i.formatMessage(q.follow_requests),badge:(e=r,t=40,0===e?void 0:t&&e>=t?t+"+":e),to:"/follow_requests"},g++)),f+=48),s||(c.push(Object(n.a)(l.a,{text:i.formatMessage(q.settings_subheading)},g++),Object(n.a)(d.a,{icon:"gears",text:i.formatMessage(q.preferences),href:"/settings/preferences"},g++)),f+=82),Object(n.a)(u.a,{bindToDocument:!s,label:i.formatMessage(q.menu)},void 0,s&&Object(n.a)("div",{className:"column-header__wrapper"},void 0,Object(n.a)("h1",{className:"column-header"},void 0,Object(n.a)("button",{},void 0,Object(n.a)(y.a,{id:"bars",className:"column-header__icon",fixedWidth:!0}),Object(n.a)(b.b,{id:"getting_started.heading",defaultMessage:"Getting started"})))),Object(n.a)("div",{className:"getting-started"},void 0,Object(n.a)("div",{className:"getting-started__wrapper",style:{height:f}},void 0,!s&&Object(n.a)(M.a,{account:o}),c),!s&&Object(n.a)("div",{className:"flex-spacer"}),Object(n.a)(k.a,{withHotkeys:s})),s&&O.s&&Object(n.a)(w.a,{}))},t}(j.a),Object(c.a)(o,"contextTypes",{router:m.a.object.isRequired}),Object(c.a)(o,"propTypes",{intl:m.a.object.isRequired,myAccount:v.a.map.isRequired,columns:v.a.list,multiColumn:m.a.bool,fetchFollowRequests:m.a.func.isRequired,unreadFollowRequests:m.a.number,unreadNotifications:m.a.number}),i=s))||i)||i},839:function(e,t,a){"use strict";var i=a(13),o=a(264),s=a(0),n=a(7),r=a(1),c=(a(3),a(18)),u=a(5),d=a.n(u),l=a(14),b=a.n(l),g=a(744),f=a(6),m=function(e){function t(){return e.apply(this,arguments)||this}Object(n.a)(t,e);var a=t.prototype;return a.componentDidMount=function(){var e=this;this.props.fetchTrends(),this.refreshInterval=setInterval((function(){return e.props.fetchTrends()}),9e5)},a.componentWillUnmount=function(){this.refreshInterval&&clearInterval(this.refreshInterval)},a.render=function(){var e=this.props.trends;return!e||e.isEmpty()?null:Object(s.a)("div",{className:"getting-started__trends"},void 0,Object(s.a)("h4",{},void 0,Object(s.a)(f.b,{id:"trends.trending_now",defaultMessage:"Trending now"})),e.take(3).map((function(e){return Object(s.a)(g.a,{hashtag:e},e.get("name"))})))},t}(c.a);Object(r.a)(m,"defaultProps",{loading:!1}),Object(r.a)(m,"propTypes",{trends:b.a.list,fetchTrends:d.a.func.isRequired});t.a=Object(i.connect)((function(e){return{trends:e.getIn(["trends","items"])}}),(function(e){return{fetchTrends:function(){return e(Object(o.d)())}}}))(m)}}]);
//# sourceMappingURL=getting_started.js.map