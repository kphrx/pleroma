(window.webpackJsonp=window.webpackJsonp||[]).push([["chunk-2b8b"],{"26YS":function(e,t,a){"use strict";a.r(t);var o=a("o0o1"),i=a.n(o),s=a("yXPU"),l=a.n(s),c=a("mm8V"),n={props:{host:{type:String,required:!0},packName:{type:String,required:!0},name:{type:String,required:!0},file:{type:String,required:!0},isLocal:{type:Boolean,required:!0}},data:function(){return{newName:null,newFile:null,copyToLocalPackName:null,copyPopoverVisible:!1,copyToShortcode:"",copyToFilename:""}},computed:{emojiName:{get:function(){return null!==this.newName?this.newName:this.name},set:function(e){this.newName=e}},emojiFile:{get:function(){return null!==this.newFile?this.newFile:this.file},set:function(e){this.newFile=e}},isDesktop:function(){return"desktop"===this.$store.state.app.device},isMobile:function(){return"mobile"===this.$store.state.app.device},localPacks:function(){return this.$store.state.emojiPacks.localPacks},remoteInstance:function(){return this.$store.state.emojiPacks.remoteInstance}},methods:{update:function(){var e=this;this.$store.dispatch("UpdateAndSavePackFile",{action:"update",packName:this.packName,oldName:this.name,newName:this.emojiName,newFilename:this.emojiFile}).then(function(){e.newName=null,e.newFile=null,e.$store.dispatch("ReloadEmoji")})},remove:function(){var e=this;this.$confirm("This will delete the emoji, are you sure?","Warning",{confirmButtonText:"Yes, delete the emoji",cancelButtonText:"No, leave it be",type:"warning"}).then(function(){e.$store.dispatch("UpdateAndSavePackFile",{action:"remove",packName:e.packName,name:e.name}).then(function(){e.newName=null,e.newFile=null,e.$store.dispatch("ReloadEmoji")})})},copyToLocal:function(){var e=this;this.$store.dispatch("UpdateAndSavePackFile",{action:"add",packName:this.copyToLocalPackName,shortcode:""!==this.copyToShortcode.trim()?this.copyToShortcode.trim():this.name,fileName:""!==this.copyToFilename.trim()?this.copyToFilename.trim():this.file,file:this.addressOfEmojiInPack(this.host,this.packName,this.file)}).then(function(){e.copyToLocalPackName=null,e.copyToLocalVisible=!1,e.copyToShortcode="",e.copyToFilename="",e.$store.dispatch("ReloadEmoji")})},addressOfEmojiInPack:c.a}},r=(a("4ySm"),a("KHd+")),m=Object(r.a)(n,function(){var e=this,t=e.$createElement,a=e._self._c||t;return a("div",[e.isLocal?a("div",{class:e.isMobile?"emoji-container-flex":"emoji-container-grid"},[a("img",{staticClass:"emoji-preview-img",attrs:{src:e.addressOfEmojiInPack(e.host,e.packName,e.file)}}),e._v(" "),a("el-input",{staticClass:"emoji-info",attrs:{placeholder:e.$t("emoji.shortcode")},model:{value:e.emojiName,callback:function(t){e.emojiName=t},expression:"emojiName"}}),e._v(" "),a("el-input",{staticClass:"emoji-info",attrs:{placeholder:e.$t("emoji.file")},model:{value:e.emojiFile,callback:function(t){e.emojiFile=t},expression:"emojiFile"}}),e._v(" "),a("div",{staticClass:"emoji-buttons"},[a("el-button",{attrs:{type:"primary"},on:{click:e.update}},[e._v(e._s(e.$t("emoji.update")))]),e._v(" "),a("el-button",{staticClass:"remove-emoji-button",on:{click:e.remove}},[e._v(e._s(e.$t("emoji.remove")))])],1)],1):e._e(),e._v(" "),e.isLocal?e._e():a("div",{class:e.isMobile?"emoji-container-flex":"remote-emoji-container-grid"},[a("img",{staticClass:"emoji-preview-img",attrs:{src:e.addressOfEmojiInPack(e.remoteInstance,e.packName,e.file)}}),e._v(" "),a("el-input",{staticClass:"emoji-info",attrs:{value:e.emojiName,placeholder:e.$t("emoji.shortcode")}}),e._v(" "),a("el-input",{staticClass:"emoji-info",attrs:{value:e.emojiFile,placeholder:e.$t("emoji.file")}}),e._v(" "),a("el-popover",{staticClass:"copy-pack-container",attrs:{placement:"left-start","popper-class":"copy-popover"},model:{value:e.copyPopoverVisible,callback:function(t){e.copyPopoverVisible=t},expression:"copyPopoverVisible"}},[a("p",[e._v(e._s(e.$t("emoji.selectLocalPack")))]),e._v(" "),a("el-select",{staticClass:"copy-pack-select",attrs:{placeholder:e.$t("emoji.localPack")},model:{value:e.copyToLocalPackName,callback:function(t){e.copyToLocalPackName=t},expression:"copyToLocalPackName"}},e._l(e.localPacks,function(e,t){return a("el-option",{key:t,attrs:{label:t,value:t}})}),1),e._v(" "),a("p",[e._v(e._s(e.$t("emoji.specifyShortcode")))]),e._v(" "),a("el-input",{attrs:{placeholder:e.$t("emoji.leaveEmptyShortcode")},model:{value:e.copyToShortcode,callback:function(t){e.copyToShortcode=t},expression:"copyToShortcode"}}),e._v(" "),a("p",[e._v(e._s(e.$t("emoji.specifyFilename")))]),e._v(" "),a("el-input",{attrs:{placeholder:e.$t("emoji.leaveEmptyFilename")},model:{value:e.copyToFilename,callback:function(t){e.copyToFilename=t},expression:"copyToFilename"}}),e._v(" "),a("el-button",{attrs:{disabled:!e.copyToLocalPackName,type:"primary"},on:{click:e.copyToLocal}},[e._v(e._s(e.$t("emoji.copy")))]),e._v(" "),a("el-button",{staticClass:"emoji-button",attrs:{slot:"reference",type:"primary"},slot:"reference"},[e._v(e._s(e.$t("emoji.copyToLocalPack")))])],1)],1)])},[],!1,null,null,null);m.options.__file="SingleEmojiEditor.vue";var p=m.exports,d={props:{packName:{type:String,required:!0}},data:function(){return{shortcode:"",imageUploadURL:"",customFileName:""}},computed:{isDesktop:function(){return"desktop"===this.$store.state.app.device},isMobile:function(){return"mobile"===this.$store.state.app.device},shortcodePresent:function(){return""===this.shortcode.trim()}},methods:{uploadEmoji:function(e){var t=this,a=e.file;this.$store.dispatch("UpdateAndSavePackFile",{action:"add",packName:this.packName,shortcode:this.shortcode,file:a||this.imageUploadURL,fileName:this.customFileName}).then(function(){t.shortcode="",t.imageUploadURL="",t.customFileName="",t.$store.dispatch("ReloadEmoji")})}}},u=(a("IVv3"),Object(r.a)(d,function(){var e=this,t=e.$createElement,a=e._self._c||t;return a("el-form",{staticClass:"new-emoji-uploader-form",attrs:{"label-position":e.isMobile?"top":"left","label-width":"130px",size:"small"}},[a("el-form-item",{attrs:{label:e.$t("emoji.shortcode")}},[a("el-input",{attrs:{placeholder:e.$t("emoji.required")},model:{value:e.shortcode,callback:function(t){e.shortcode=t},expression:"shortcode"}})],1),e._v(" "),a("el-form-item",{attrs:{label:e.$t("emoji.customFilename")}},[a("el-input",{attrs:{placeholder:e.$t("emoji.optional")},model:{value:e.customFileName,callback:function(t){e.customFileName=t},expression:"customFileName"}})],1),e._v(" "),a("el-form-item",{attrs:{label:e.$t("emoji.uploadFile")}},[a("div",{staticClass:"upload-file-url"},[a("el-input",{attrs:{placeholder:e.$t("emoji.url")},model:{value:e.imageUploadURL,callback:function(t){e.imageUploadURL=t},expression:"imageUploadURL"}}),e._v(" "),a("el-button",{staticClass:"upload-button",attrs:{disabled:e.shortcodePresent,type:"primary"},on:{click:e.uploadEmoji}},[e._v(e._s(e.$t("emoji.upload")))])],1),e._v(" "),a("div",{staticClass:"upload-container"},[a("p",{staticClass:"text"},[e._v("or")]),e._v(" "),a("el-upload",{attrs:{"http-request":e.uploadEmoji,multiple:!1,"show-file-list":!1,action:"add"}},[a("el-button",{attrs:{disabled:e.shortcodePresent,type:"primary"}},[e._v(e._s(e.$t("emoji.clickToUpload")))])],1)],1)])],1)},[],!1,null,null,null));u.options.__file="NewEmojiUploader.vue";var h={components:{SingleEmojiEditor:p,NewEmojiUploader:u.exports},props:{name:{type:String,required:!0},pack:{type:Object,required:!0},host:{type:String,required:!0},isLocal:{type:Boolean,required:!0}},data:function(){return{showPackContent:[],downloadSharedAs:""}},computed:{isDesktop:function(){return"desktop"===this.$store.state.app.device},isMobile:function(){return"mobile"===this.$store.state.app.device},isTablet:function(){return"tablet"===this.$store.state.app.device},labelWidth:function(){return this.isMobile?"90px":(this.isTablet,"120px")},share:{get:function(){return this.pack.pack["share-files"]},set:function(e){this.$store.dispatch("UpdateLocalPackVal",{name:this.name,key:"share-files",value:e})}},homepage:{get:function(){return this.pack.pack.homepage},set:function(e){this.$store.dispatch("UpdateLocalPackVal",{name:this.name,key:"homepage",value:e})}},description:{get:function(){return this.pack.pack.description},set:function(e){this.$store.dispatch("UpdateLocalPackVal",{name:this.name,key:"description",value:e})}},license:{get:function(){return this.pack.pack.license},set:function(e){this.$store.dispatch("UpdateLocalPackVal",{name:this.name,key:"license",value:e})}},fallbackSrc:{get:function(){return this.pack.pack["fallback-src"]},set:function(e){""!==e.trim()?this.$store.dispatch("UpdateLocalPackVal",{name:this.name,key:"fallback-src",value:e}):(this.$store.dispatch("UpdateLocalPackVal",{name:this.name,key:"fallback-src",value:null}),this.$store.dispatch("UpdateLocalPackVal",{name:this.name,key:"fallback-src-sha256",value:null}))}}},methods:{downloadFromInstance:function(){var e=this;this.$store.dispatch("DownloadFrom",{instanceAddress:this.host,packName:this.name,as:this.downloadSharedAs}).then(function(){return e.$store.dispatch("ReloadEmoji")}).then(function(){return e.$store.dispatch("SetLocalEmojiPacks")})},deletePack:function(){var e=this;this.$confirm("This will delete the pack, are you sure?","Warning",{confirmButtonText:"Yes, delete the pack",cancelButtonText:"No, leave it be",type:"warning"}).then(function(){e.$store.dispatch("DeletePack",{name:e.name}).then(function(){return e.$store.dispatch("ReloadEmoji")}).then(function(){return e.$store.dispatch("SetLocalEmojiPacks")})}).catch(function(){})},savePackMetadata:function(){this.$store.dispatch("SavePackMetadata",{packName:this.name})}}},k=(a("wFa7"),Object(r.a)(h,function(){var e=this,t=e.$createElement,a=e._self._c||t;return a("el-collapse-item",{staticClass:"has-background",attrs:{title:e.name,name:e.name}},[e.isLocal?a("el-form",{staticClass:"emoji-pack-metadata",attrs:{"label-width":e.labelWidth,"label-position":"left",size:"small"}},[a("el-form-item",{attrs:{label:e.$t("emoji.sharePack")}},[a("el-switch",{model:{value:e.share,callback:function(t){e.share=t},expression:"share"}})],1),e._v(" "),a("el-form-item",{attrs:{label:e.$t("emoji.homepage")}},[a("el-input",{model:{value:e.homepage,callback:function(t){e.homepage=t},expression:"homepage"}})],1),e._v(" "),a("el-form-item",{attrs:{label:e.$t("emoji.description")}},[a("el-input",{attrs:{type:"textarea"},model:{value:e.description,callback:function(t){e.description=t},expression:"description"}})],1),e._v(" "),a("el-form-item",{attrs:{label:e.$t("emoji.license")}},[a("el-input",{model:{value:e.license,callback:function(t){e.license=t},expression:"license"}})],1),e._v(" "),a("el-form-item",{attrs:{label:e.$t("emoji.fallbackSrc")}},[a("el-input",{model:{value:e.fallbackSrc,callback:function(t){e.fallbackSrc=t},expression:"fallbackSrc"}})],1),e._v(" "),e.fallbackSrc&&""!==e.fallbackSrc.trim()?a("el-form-item",{attrs:{label:e.$t("emoji.fallbackSrcSha")}},[e._v("\n      "+e._s(e.pack.pack["fallback-src-sha256"])+"\n    ")]):e._e()],1):e._e(),e._v(" "),e.isLocal?a("div",{staticClass:"pack-button-container"},[a("div",{staticClass:"save-pack-button-container"},[a("el-button",{staticClass:"save-pack-button",attrs:{type:"primary"},on:{click:e.savePackMetadata}},[e._v(e._s(e.$t("emoji.saveMetadata")))]),e._v(" "),a("el-button",{staticClass:"delete-pack-button",on:{click:e.deletePack}},[e._v(e._s(e.$t("emoji.deletePack")))])],1),e._v(" "),a("div",{staticClass:"download-pack-button-container"},[e.pack.pack["can-download"]?a("el-link",{attrs:{href:"//"+e.host+"/api/pleroma/emoji/packs/"+e.name+"/download_shared",underline:!1,type:"primary",target:"_blank"}},[a("el-button",{staticClass:"download-archive"},[e._v(e._s(e.$t("emoji.downloadPackArchive")))])],1):e._e()],1)]):e._e(),e._v(" "),e.isLocal?e._e():a("el-form",{staticClass:"emoji-pack-metadata remote-pack-metadata",attrs:{"label-width":e.labelWidth,"label-position":"left",size:"small"}},[a("el-form-item",{attrs:{label:e.$t("emoji.sharePack")}},[a("el-switch",{attrs:{disabled:""},model:{value:e.share,callback:function(t){e.share=t},expression:"share"}})],1),e._v(" "),e.homepage?a("el-form-item",{attrs:{label:e.$t("emoji.homepage")}},[a("span",[e._v(e._s(e.homepage))])]):e._e(),e._v(" "),e.description?a("el-form-item",{attrs:{label:e.$t("emoji.description")}},[a("span",[e._v(e._s(e.description))])]):e._e(),e._v(" "),e.license?a("el-form-item",{attrs:{label:e.$t("emoji.license")}},[a("span",[e._v(e._s(e.license))])]):e._e(),e._v(" "),e.fallbackSrc?a("el-form-item",{attrs:{label:e.$t("emoji.fallbackSrc")}},[a("span",[e._v(e._s(e.fallbackSrc))])]):e._e(),e._v(" "),e.fallbackSrc&&""!==e.fallbackSrc.trim()?a("el-form-item",{attrs:{label:e.$t("emoji.fallbackSrcSha")}},[e._v("\n      "+e._s(e.pack.pack["fallback-src-sha256"])+"\n    ")]):e._e(),e._v(" "),a("el-form-item",[e.pack.pack["can-download"]?a("el-link",{attrs:{href:"//"+e.host+"/api/pleroma/emoji/packs/"+e.name+"/download_shared",underline:!1,type:"primary",target:"_blank"}},[a("el-button",{staticClass:"download-archive"},[e._v(e._s(e.$t("emoji.downloadPackArchive")))])],1):e._e()],1)],1),e._v(" "),a("el-collapse",{staticClass:"contents-collapse",model:{value:e.showPackContent,callback:function(t){e.showPackContent=t},expression:"showPackContent"}},[e.isLocal?a("el-collapse-item",{staticClass:"no-background",attrs:{title:e.$t("emoji.addNewEmoji"),name:"addEmoji"}},[a("new-emoji-uploader",{attrs:{"pack-name":e.name}})],1):e._e(),e._v(" "),Object.keys(e.pack.files).length>0?a("el-collapse-item",{staticClass:"no-background",attrs:{title:e.$t("emoji.manageEmoji"),name:"manageEmoji"}},e._l(e.pack.files,function(t,o){return a("single-emoji-editor",{key:o,attrs:{host:e.host,"pack-name":e.name,name:o,file:t,"is-local":e.isLocal}})}),1):e._e(),e._v(" "),e.isLocal?e._e():a("el-collapse-item",{staticClass:"no-background",attrs:{title:e.$t("emoji.downloadPack"),name:"downloadPack"}},[a("p",[e._v("\n        "+e._s(e.$t("emoji.thisWillDownload"))+' "'+e._s(e.name)+'" '+e._s(e.$t("emoji.downloadToCurrentInstance"))+'\n        "'+e._s(""===e.downloadSharedAs.trim()?e.name:e.downloadSharedAs)+'" ('+e._s(e.$t("emoji.canBeChanged"))+").\n        "+e._s(e.$t("emoji.willBeUsable"))+".\n      ")]),e._v(" "),a("div",{staticClass:"download-shared-pack"},[a("el-input",{attrs:{placeholder:e.$t("emoji.downloadAsOptional")},model:{value:e.downloadSharedAs,callback:function(t){e.downloadSharedAs=t},expression:"downloadSharedAs"}}),e._v(" "),a("el-button",{staticClass:"download-shared-pack-button",attrs:{type:"primary"},on:{click:e.downloadFromInstance}},[e._v("\n          "+e._s(e.isDesktop?e.$t("emoji.downloadSharedPack"):e.$t("emoji.downloadSharedPackMobile"))+"\n        ")])],1)])],1)],1)},[],!1,null,null,null));k.options.__file="EmojiPack.vue";var f=k.exports,v=a("mSNy"),b={components:{EmojiPack:f},data:function(){return{remoteInstanceAddress:"",newPackName:"",activeLocalPack:[],activeRemotePack:[]}},computed:{isMobile:function(){return"mobile"===this.$store.state.app.device},isTablet:function(){return"tablet"===this.$store.state.app.device},labelWidth:function(){return this.isMobile?"105px":this.isTablet?"180px":"240px"},localPacks:function(){return this.$store.state.emojiPacks.localPacks},remotePacks:function(){return this.$store.state.emojiPacks.remotePacks}},mounted:function(){this.refreshLocalPacks()},methods:{createLocalPack:function(){var e=this;this.$store.dispatch("CreatePack",{name:this.newPackName}).then(function(){e.newPackName="",e.$store.dispatch("SetLocalEmojiPacks"),e.$store.dispatch("ReloadEmoji")})},refreshLocalPacks:function(){try{this.$store.dispatch("SetLocalEmojiPacks")}catch(e){return}this.$message({type:"success",message:v.a.t("emoji.refreshed")})},refreshRemotePacks:function(){this.$store.dispatch("SetRemoteEmojiPacks",{remoteInstance:this.remoteInstanceAddress})},reloadEmoji:function(){var e=l()(i.a.mark(function e(){return i.a.wrap(function(e){for(;;)switch(e.prev=e.next){case 0:e.prev=0,this.$store.dispatch("ReloadEmoji"),e.next=7;break;case 4:return e.prev=4,e.t0=e.catch(0),e.abrupt("return");case 7:this.$message({type:"success",message:v.a.t("emoji.reloaded")});case 8:case"end":return e.stop()}},e,this,[[0,4]])}));return function(){return e.apply(this,arguments)}}(),importFromFS:function(){var e=this;this.$store.dispatch("ImportFromFS").then(function(){e.$store.dispatch("SetLocalEmojiPacks"),e.$store.dispatch("ReloadEmoji")})}}},_=(a("smuD"),Object(r.a)(b,function(){var e=this,t=e.$createElement,a=e._self._c||t;return a("div",{staticClass:"emoji-packs"},[a("h1",{staticClass:"emoji-packs-header"},[e._v(e._s(e.$t("emoji.emojiPacks")))]),e._v(" "),a("div",{staticClass:"emoji-packs-header-button-container"},[a("el-button",{staticClass:"reload-emoji-button",attrs:{type:"primary"},on:{click:e.reloadEmoji}},[e._v(e._s(e.$t("emoji.reloadEmoji")))]),e._v(" "),a("el-tooltip",{staticClass:"import-pack-button",attrs:{content:e.$t("emoji.importEmojiTooltip"),effects:"dark",placement:"bottom"}},[a("el-button",{attrs:{type:"primary"},on:{click:e.importFromFS}},[e._v("\n        "+e._s(e.$t("emoji.importPacks"))+"\n      ")])],1)],1),e._v(" "),a("el-divider",{staticClass:"divider"}),e._v(" "),a("el-form",{staticClass:"emoji-packs-form",attrs:{"label-width":e.labelWidth}},[a("el-form-item",{attrs:{label:e.$t("emoji.localPacks")}},[a("el-button",{attrs:{type:"primary"},on:{click:e.refreshLocalPacks}},[e._v(e._s(e.$t("emoji.refreshLocalPacks")))])],1),e._v(" "),a("el-form-item",{attrs:{label:e.$t("emoji.createLocalPack")}},[a("div",{staticClass:"create-pack"},[a("el-input",{attrs:{placeholder:e.$t("users.name")},model:{value:e.newPackName,callback:function(t){e.newPackName=t},expression:"newPackName"}}),e._v(" "),a("el-button",{staticClass:"create-pack-button",attrs:{disabled:""===e.newPackName.trim()},on:{click:e.createLocalPack}},[e._v("\n          "+e._s(e.$t("users.create"))+"\n        ")])],1)]),e._v(" "),Object.keys(e.localPacks).length>0?a("el-form-item",{attrs:{label:e.$t("emoji.packs")}},e._l(e.localPacks,function(t,o){return a("el-collapse",{key:o,model:{value:e.activeLocalPack,callback:function(t){e.activeLocalPack=t},expression:"activeLocalPack"}},[a("emoji-pack",{attrs:{name:o,pack:t,host:e.$store.getters.authHost,"is-local":!0}})],1)}),1):e._e(),e._v(" "),a("el-divider",{staticClass:"divider"}),e._v(" "),a("el-form-item",{attrs:{label:e.$t("emoji.remotePacks")}},[a("div",{staticClass:"create-pack"},[a("el-input",{attrs:{placeholder:e.$t("emoji.remoteInstanceAddress")},model:{value:e.remoteInstanceAddress,callback:function(t){e.remoteInstanceAddress=t},expression:"remoteInstanceAddress"}}),e._v(" "),a("el-button",{staticClass:"create-pack-button",attrs:{disabled:""===e.remoteInstanceAddress.trim()},on:{click:e.refreshRemotePacks}},[e._v("\n          "+e._s(e.$t("emoji.refreshRemote"))+"\n        ")])],1)]),e._v(" "),Object.keys(e.remotePacks).length>0?a("el-form-item",{attrs:{label:e.$t("emoji.packs")}},e._l(e.remotePacks,function(t,o){return a("el-collapse",{key:o,model:{value:e.activeRemotePack,callback:function(t){e.activeRemotePack=t},expression:"activeRemotePack"}},[a("emoji-pack",{attrs:{name:o,pack:t,host:e.$store.getters.authHost,"is-local":!1}})],1)}),1):e._e()],1)],1)},[],!1,null,null,null));_.options.__file="index.vue";t.default=_.exports},"4ySm":function(e,t,a){"use strict";var o=a("n6gr");a.n(o).a},"6lYW":function(e,t,a){},IVv3:function(e,t,a){"use strict";var o=a("6lYW");a.n(o).a},QZC8:function(e,t,a){},n6gr:function(e,t,a){},sW7V:function(e,t,a){},smuD:function(e,t,a){"use strict";var o=a("QZC8");a.n(o).a},wFa7:function(e,t,a){"use strict";var o=a("sW7V");a.n(o).a}}]);
//# sourceMappingURL=chunk-2b8b.e3daf966.js.map