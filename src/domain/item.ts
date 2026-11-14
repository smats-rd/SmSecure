export type ItemId = string;

export interface Item {
  readonly id: ItemId;
  readonly identityRuleVersion: string;
  readonly identityKey: string;
}
