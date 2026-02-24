local api = require("api")
local lib = {}

local lib_addon = {
    name = "Addon Menu Bar",
    author = "Michaelqt",
    version = "1.0",
    desc = "A library to help create addon configuration menus."
}

function initializeMichaelClient()
    local configMenu = ADDON:GetContent(UIC.SYSTEM_CONFIG_FRAME)
    if configMenu.michaelClient == nil then
        local michaelClient = configMenu:CreateChildWidget("label", "michaelClient", 0, true)
        michaelClient:AddAnchor("TOPLEFT", configMenu, -110, 5)
        michaelClient:SetExtent(110, 28)
        michaelClient:SetText("Addon Options")
        configMenu.michaelClient = michaelClient
        configMenu.michaelClient.addons = {}

        michaelClient.bg = michaelClient:CreateNinePartDrawable("ui/common/tab_list.dds", "background")
        michaelClient.bg:SetTextureInfo("bg_quest")
        michaelClient.bg:SetColor(0, 0, 0, 0.5)
        michaelClient.bg:AddAnchor("TOPLEFT", michaelClient, 0, 0)
        michaelClient.bg:AddAnchor("BOTTOMRIGHT", michaelClient, 0, 0)

        michaelClient.addonCount = 0
        function configMenu.michaelClient:AddAddon(title, callback)
            self.addonCount = self.addonCount + 1
            if not self.addons[title] then
                local addonButton = self:CreateChildWidget("button", title, 0, true)
                addonButton:SetText(title)
                addonButton:AddAnchor("TOPLEFT", michaelClient, 5, michaelClient.addonCount * 30)
                addonButton:SetExtent(100, 28)
                addonButton:SetHandler("OnClick", function()
                    callback()
                end)
                -- Addon button styling
                addonButton.bg = addonButton:CreateNinePartDrawable("ui/common/tab_list.dds", "background")
                addonButton.bg:SetTextureInfo("bg_quest")
                addonButton.bg:SetColor(0, 0, 0, 0.5)
                addonButton.bg:AddAnchor("TOPLEFT", addonButton, 0, 0)
                addonButton.bg:AddAnchor("BOTTOMRIGHT", addonButton, 0, 0)


                self.addons[title] = addonButton
            end
            -- Also redraw the background
            local currentWidth = michaelClient.bg:GetWidth()
            local currentHeight = self.addonCount * 30
            -- michaelClient:SetExtent(currentWidth, currentHeight)
            michaelClient.bg:SetExtent(currentWidth, currentHeight)
            michaelClient.bg:RemoveAllAnchors()
            michaelClient.bg:AddAnchor("TOPLEFT", michaelClient, 0, 0)
            michaelClient.bg:AddAnchor("BOTTOMRIGHT", michaelClient, 0,  michaelClient.addonCount * 30 + 10)
        end
    end
    return configMenu
end
lib.initializeMichaelClient = initializeMichaelClient

function OnUnload()
    local configMenu = ADDON:GetContent(UIC.SYSTEM_CONFIG_FRAME)
	if configMenu.michaelClient ~= nil then
		configMenu.michaelClient:Show(false)
		api.Interface:Free(configMenu.michaelClient)
		configMenu.michaelClient = nil
	end
end
lib.OnUnload = OnUnload

return lib